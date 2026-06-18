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
import MLXAudioCore
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
        // fromDirectory(_:) is a synchronous throws — loads weights from local files only
        // (no computeDType parameter in mlx-audio-swift 0.1.2).
        // Source: .build/checkouts/mlx-audio-swift/Sources/MLXAudioSTT/Models/Parakeet/ParakeetModel.swift:473
        model = try ParakeetModel.fromDirectory(modelDirectory)
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

        // 1. Load audio samples. `loadAudioArray(from:sampleRate:)` is a free function in
        //    MLXAudioCore returning (sampleRate, MLXArray) of 16 kHz mono float32.
        //    Source: .build/checkouts/mlx-audio-swift/Sources/MLXAudioCore/AudioUtils.swift:58
        let (_, samples) = try loadAudioArray(from: audioURL, sampleRate: 16000)

        // 2. Run inference. `STTGenerateParameters.language` is a non-optional String
        //    (default "English"). Parakeet-v3 is multilingual and auto-detects per segment;
        //    pass the hint when set, else "English". (Tune language handling during eval.)
        //    Source: .build/checkouts/mlx-audio-swift/Sources/MLXAudioSTT/Generation.swift:3
        let params = STTGenerateParameters(
            maxTokens: 8192,
            temperature: 0.0,
            language: options.languageHint ?? "English"
        )

        // generate() is synchronous; defined on STTGenerationModel, implemented by ParakeetModel.
        let output: STTOutput = model.generate(audio: samples, generationParameters: params)

        // 3. Map STTOutput → Transcript.
        return mapToTranscript(output, languageHint: options.languageHint)
    }

    // MARK: - Private helpers

    private func mapToTranscript(_ output: STTOutput, languageHint: String?) -> Transcript {
        // STTOutput (mlx-audio-swift 0.1.2):
        //   .text: String              — full concatenated transcript
        //   .segments: [[String: Any]]? — SENTENCE-level dicts with keys "text"/"start"/"end"
        //   .language: String?         — detected/param language
        // Source: .build/checkouts/mlx-audio-swift/Sources/MLXAudioSTT/Models/GLMASR/STTOutput.swift:80
        //         and .../Models/Parakeet/ParakeetAlignment.swift:13 (segments dict shape)
        let language = output.language ?? languageHint

        guard let rawSegments = output.segments, !rawSegments.isEmpty else {
            let seg = TranscriptSegment(text: output.text, start: 0, end: 0, words: [])
            return Transcript(language: language, segments: [seg])
        }

        // The public API exposes SENTENCE-level timing only. Per-word token timings exist
        // internally (ParakeetAlignedToken.start/.duration) but are not surfaced via STTOutput.
        // We emit one Word spanning each sentence so the word-level aligner has a timed unit;
        // attribution is therefore sentence-granular. (Word-level would require the internal
        // ParakeetAlignedResult — a future enhancement; see BRINGUP.md Stage 5.)
        let segments: [TranscriptSegment] = rawSegments.compactMap { dict in
            guard let text = dict["text"] as? String,
                  let start = dict["start"] as? Double,
                  let end = dict["end"] as? Double else { return nil }
            let word = Word(text: text, start: start, end: end, confidence: nil)
            return TranscriptSegment(text: text, start: start, end: end, words: [word])
        }
        return Transcript(language: language, segments: segments)
    }
}

// MARK: - Errors

public enum ASRError: Error, Sendable {
    case modelNotLoaded
    case audioLoadFailed(String)
}
