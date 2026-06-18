// WhisperKitEngine.swift — TatlinML
//
// Fallback ASREngine backed by WhisperKit large-v3 (argmaxinc/WhisperKit v1.0.0).
//
// Source references:
//   Protocol:       Sources/TatlinKit/Transcription/Transcript.swift
//   WhisperKit init:
//     https://github.com/argmaxinc/WhisperKit/blob/main/Sources/WhisperKit/Core/WhisperKit.swift
//   transcribe(audioPath:decodeOptions:):
//     https://github.com/argmaxinc/WhisperKit/blob/main/Sources/WhisperKit/Core/WhisperKit.swift
//   DecodingOptions (wordTimestamps: Bool):
//     https://github.com/argmaxinc/whisperkit/blob/main/Sources/WhisperKit/Core/Configurations.swift
//   WordTiming (word, start, end, probability):
//     https://github.com/argmaxinc/WhisperKit/blob/main/Sources/WhisperKit/Core/Models.swift
//   TranscriptionSegment (text, start, end, words: [WordTiming]?):
//     https://github.com/argmaxinc/WhisperKit/blob/main/Sources/WhisperKit/Core/Models.swift

import Foundation
import WhisperKit
import TatlinKit

/// Fallback ASR engine using WhisperKit large-v3.  Provides mature word-level timestamps
/// via `DecodingOptions.wordTimestamps = true` → `TranscriptionSegment.words: [WordTiming]`.
///
/// Use this engine when Parakeet is unavailable or as a quality cross-reference in the
/// eval harness (plan.md M1B.3).
@available(macOS 15, *)
public actor WhisperKitEngine: ASREngine {

    // MARK: - ASREngine

    public nonisolated let modelID = "whisperkit-large-v3"

    // MARK: - Private state

    /// WhisperKit is a reference type; we hold it as an optional until `load()` is called.
    private var whisper: WhisperKit?

    /// Local folder path that contains the WhisperKit compiled CoreML models
    /// (the folder ModelStore downloaded and compiled from the argmax HF repo).
    private let modelFolder: String

    // MARK: - Init

    /// - Parameter modelDirectory: Directory containing the WhisperKit CoreML model artifacts
    ///   (`.mlmodelc` bundles + `config.json`).  Pass the value resolved by `ModelStore`.
    public init(modelDirectory: URL) {
        self.modelFolder = modelDirectory.path
    }

    // MARK: - Load / unload

    /// Download (if needed) and load the WhisperKit pipeline.
    ///
    /// WhisperKit initialisation is `async throws` and performs CoreML compilation.
    /// Source: https://github.com/argmaxinc/WhisperKit/blob/main/Sources/WhisperKit/Core/WhisperKit.swift
    public func load() async throws {
        guard whisper == nil else { return }
        // `modelFolder` points to a pre-downloaded directory; WhisperKit skips download.
        // Source: https://github.com/argmaxinc/WhisperKit/blob/main/Sources/WhisperKit/Core/WhisperKit.swift
        whisper = try await WhisperKit(modelFolder: modelFolder)
    }

    /// Release the WhisperKit pipeline; CoreML models are freed on dealloc.
    public func unload() {
        whisper = nil
    }

    // MARK: - ASREngine conformance

    /// Transcribe a 16 kHz mono audio file using Whisper large-v3.
    ///
    /// Word timestamps are always requested; they are gated by `DecodingOptions.wordTimestamps`.
    /// Source for `DecodingOptions`:
    ///   https://github.com/argmaxinc/whisperkit/blob/main/Sources/WhisperKit/Core/Configurations.swift
    public func transcribe(audioURL: URL, options: ASROptions) async throws -> Transcript {
        guard let whisper else {
            throw ASRError.modelNotLoaded
        }

        // Build DecodingOptions.
        // DecodingOptions is a Codable/Sendable struct with sensible defaults.
        // `wordTimestamps: Bool` — enables per-word timing in TranscriptionSegment.words.
        // Source: https://github.com/argmaxinc/whisperkit/blob/main/Sources/WhisperKit/Core/Configurations.swift
        var decodeOptions = DecodingOptions()
        decodeOptions.wordTimestamps = options.wordTimestamps
        if let lang = options.languageHint {
            decodeOptions.language = lang
            decodeOptions.detectLanguage = false
        } else {
            decodeOptions.detectLanguage = true
        }
        // Skip special tokens keeps transcription clean; WhisperKit default is true.
        decodeOptions.skipSpecialTokens = true

        // transcribe(audioPath:decodeOptions:) — returns [TranscriptionResult].
        // Each result covers a chunk of audio; we concatenate.
        // Source: https://github.com/argmaxinc/WhisperKit/blob/main/Sources/WhisperKit/Core/WhisperKit.swift
        let results: [TranscriptionResult] = try await whisper.transcribe(
            audioPath: audioURL.path,
            decodeOptions: decodeOptions
        )

        return mapToTranscript(results)
    }

    // MARK: - Private helpers

    private func mapToTranscript(_ results: [TranscriptionResult]) -> Transcript {
        // TranscriptionResult.language — BCP-47 language code detected by Whisper.
        // Source: https://github.com/argmaxinc/WhisperKit/blob/main/Sources/WhisperKit/Core/Models.swift
        let language = results.first?.language

        // TranscriptionResult.segments: [TranscriptionSegment]
        // TranscriptionSegment:
        //   .text: String
        //   .start: Float   — seconds
        //   .end: Float     — seconds
        //   .words: [WordTiming]?  — populated when wordTimestamps=true
        // WordTiming:
        //   .word: String
        //   .start: Float
        //   .end: Float
        //   .probability: Float
        // Source: https://github.com/argmaxinc/WhisperKit/blob/main/Sources/WhisperKit/Core/Models.swift

        var tatlinSegments: [TranscriptSegment] = []

        for result in results {
            for seg in result.segments {
                let words: [Word]
                if let wts = seg.words {
                    words = wts.map { wt in
                        Word(
                            text: wt.word,
                            start: TimeInterval(wt.start),
                            end: TimeInterval(wt.end),
                            confidence: Double(wt.probability)
                        )
                    }
                } else {
                    words = []
                }

                tatlinSegments.append(TranscriptSegment(
                    text: seg.text,
                    start: TimeInterval(seg.start),
                    end: TimeInterval(seg.end),
                    words: words
                ))
            }
        }

        return Transcript(language: language, segments: tatlinSegments)
    }
}
