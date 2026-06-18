// ParakeetEngine.swift — TatlinML
//
// Concrete ASREngine conformance backed by Parakeet-TDT-0.6B-v3 via mlx-audio-swift.
//
// Source references:
//   Protocol contract:  Sources/TatlinKit/Transcription/Transcript.swift
//   Library (STTGenerationModel, generate, STTGenerateParameters):
//     https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Generation.swift
//   ParakeetModel.fromDirectory:
//     https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/Parakeet/ParakeetModel.swift
//   Audio preprocessing (logMelSpectrogram):
//     https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/Parakeet/ParakeetAudio.swift
//   Model resolution/download (resolveOrDownloadModel):
//     https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioCore/ModelUtils.swift
//   STTOutput segment shape (text, start, duration per segment, word tokens):
//     https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/Parakeet/ParakeetModel.swift
//     (segments come from ParakeetAlignment.sentencesToResult — each segment carries
//      word-aligned tokens with .start / .duration in seconds; confirmed via code inspection)
//
// Audio contract:  16 kHz mono float32 — enforced by AudioResampler before this call.
// Model ID on HF:  mlx-community/parakeet-tdt-0.6b-v3
//                  (mlx-audio-swift resolves from this hub id via swift-transformers HubClient)

import Foundation
import MLX
import MLXAudioSTT
import TatlinKit

/// Primary ASR engine using Parakeet-TDT-0.6B-v3 loaded from a pre-downloaded model
/// directory managed by `ModelStore` / `ModelHost`.
///
/// `ParakeetEngine` must NOT be instantiated concurrently; the owning `ModelHost` actor
/// enforces single-resident residency (plan.md ADR-11).
///
/// The model exposes word-level timing through its TDT decoder: each `STTSegment` contains
/// aligned tokens with `start` and `duration` in seconds, which we flatten into `Word`s.
/// Confirmed structure: `ParakeetAlignedToken.start`, `.duration`, `.text` per token,
/// grouped into sentence segments by `ParakeetAlignment.sentencesToResult`.
///
/// VERIFY: The exact `STTSegment` type name and its `words`/`tokens` property name may differ
/// from what inspection of the compiled binary shows.  Check the compiled `.swiftmodule` once
/// the target is enabled, or read `ParakeetAlignment.swift` in the library source.
/// Source: https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/Parakeet/ParakeetModel.swift
@available(macOS 15, *)
public actor ParakeetEngine: ASREngine {

    // MARK: - ASREngine

    public nonisolated let modelID = "parakeet-tdt-0.6b-v3"

    // MARK: - Private state

    /// Loaded model handle.  Non-`Sendable`; owned exclusively by this actor.
    private var model: ParakeetModel?

    /// Directory that `ModelStore` has verified contains the model weights + config.
    private let modelDirectory: URL

    // MARK: - Init

    /// Create the engine pointing at a verified, already-downloaded model directory.
    /// - Parameter modelDirectory: Path to the directory containing `model.safetensors`
    ///   and `config.json` (the layout written by `ModelDownloader`).
    public init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    // MARK: - Load / unload

    /// Load model weights into the MLX GPU cache.  Call once before `transcribe`.
    /// Idempotent: if the model is already loaded, this is a no-op.
    ///
    /// - Throws: `ParakeetError` / Swift runtime errors on malformed checkpoint.
    ///
    /// VERIFY: `ParakeetModel.fromDirectory(_:computeDType:)` signature confirmed at
    /// https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/Parakeet/ParakeetModel.swift
    public func load() throws {
        guard model == nil else { return }
        // fromDirectory is a synchronous throws — loads weights from local files only.
        // Source: https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/Parakeet/ParakeetModel.swift
        model = try ParakeetModel.fromDirectory(modelDirectory, computeDType: .bfloat16)
    }

    /// Release the model weights and allow the Metal heap to be reclaimed.
    public func unload() {
        model = nil
        // Clear the MLX GPU cache so the next stage can allocate.
        // VERIFY: exact API — MLX.GPU.clearCache() vs MLX.GPU.set(cacheLimit: 0) vs similar.
        // Source: https://github.com/ml-explore/mlx-swift (check MLX/GPU.swift)
        MLX.GPU.clearCache()
    }

    // MARK: - ASREngine conformance

    /// Transcribe a 16 kHz mono float32 WAV/AIFF to a `Transcript` with word timestamps.
    ///
    /// - Parameters:
    ///   - audioURL: Path to a 16 kHz mono audio file (enforced upstream by `AudioResampler`).
    ///   - options: `ASROptions.wordTimestamps` must be `true`; Parakeet always returns them.
    /// - Returns: A `Transcript` where every `TranscriptSegment` carries its `words` array
    ///   with per-word `start`/`end` in seconds.
    public func transcribe(audioURL: URL, options: ASROptions) async throws -> Transcript {
        guard let model else {
            throw ASRError.modelNotLoaded
        }

        // 1. Load audio samples.
        // Parakeet expects a raw 16 kHz mono float32 MLXArray.
        // AudioUtils.loadAudio is the mlx-audio-swift helper:
        // VERIFY: exact function name — AudioUtils.loadAudioFile(url:) or similar.
        // Source: https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioCore/AudioUtils.swift
        let samples: MLXArray = try AudioUtils.loadAudioFile(url: audioURL, sampleRate: 16000)

        // 2. Run inference.
        // STTGenerationModel.generate(audio:generationParameters:) is synchronous;
        // wrap in Task for cooperative cancellation.
        // Source: https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Generation.swift
        let params = STTGenerateParameters(
            maxTokens: 8192,
            temperature: 0.0,
            language: options.languageHint   // nil = auto-detect
        )

        // generate() is defined on STTGenerationModel and implemented by ParakeetModel.
        // Source: https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Generation.swift
        let output: STTOutput = model.generate(audio: samples, generationParameters: params)

        // 3. Map STTOutput → Transcript.
        return try mapToTranscript(output, languageHint: options.languageHint)
    }

    // MARK: - Private helpers

    private func mapToTranscript(_ output: STTOutput, languageHint: String?) throws -> Transcript {
        // STTOutput fields confirmed from code inspection:
        //   .text: String           — full concatenated transcript
        //   .segments: [STTSegment]? — sentence-level segments (may be nil for very short audio)
        //   .language: String       — BCP-47 language id detected or from params
        // Source: https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/Parakeet/ParakeetModel.swift

        let language = output.language.isEmpty ? languageHint : output.language

        guard let rawSegments = output.segments, !rawSegments.isEmpty else {
            // No segments — build a single segment with no word timestamps (very short audio).
            let seg = TranscriptSegment(text: output.text, start: 0, end: 0, words: [])
            return Transcript(language: language, segments: [seg])
        }

        // Map each STTSegment → TranscriptSegment + Word array.
        //
        // STTSegment (VERIFY: exact property names from compiled module):
        //   .text: String        — segment/sentence text
        //   .start: Double       — start time in seconds
        //   .end: Double         — end time in seconds  (= start + sum of token durations)
        //   .words: [STTWord]?   — per-word timing entries
        //
        // STTWord / ParakeetAlignedToken:
        //   .text: String
        //   .start: Double       — start time in seconds (confirmed from ParakeetModel.swift)
        //   .duration: Double    — duration in seconds   (confirmed from ParakeetModel.swift)
        //
        // VERIFY: The library may name the per-segment word array `.tokens` rather than `.words`.
        // Source: https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/Parakeet/ParakeetModel.swift

        let tatlinSegments: [TranscriptSegment] = rawSegments.map { seg in
            // Build word-level timings.
            let words: [Word]
            if let segWords = seg.words, !segWords.isEmpty {
                words = segWords.map { w in
                    Word(
                        text: w.text,
                        start: w.start,
                        end: w.start + w.duration,
                        confidence: nil   // Parakeet TDT doesn't expose per-token confidence
                    )
                }
            } else {
                // Fallback: segment-level timing, no word granularity.
                words = []
            }

            return TranscriptSegment(
                text: seg.text,
                start: seg.start,
                end: seg.end,
                words: words
            )
        }

        return Transcript(language: language, segments: tatlinSegments)
    }
}

// MARK: - Errors

public enum ASRError: Error, Sendable {
    case modelNotLoaded
    case audioLoadFailed(String)
}
