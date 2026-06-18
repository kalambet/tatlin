// VoxtralEngine.swift — TatlinML
//
// Bake-off ASREngine using Voxtral-Mini-4B-Realtime-2602 via mlx-audio-swift.
//
// Source references:
//   Protocol contract:  Sources/TatlinKit/Transcription/Transcript.swift
//   Library (VoxtralRealtime model, generate API):
//     https://github.com/Blaizzy/mlx-audio-swift/tree/main/Sources/MLXAudioSTT/Models/VoxtralRealtime
//   Word-timestamp research:
//     research.md Q2 / D1 — "open Voxtral cannot emit usable timestamps" — full rationale there.
//   VoxtralRealtime README:
//     https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/VoxtralRealtime/README.md
//
// ### Word-Timestamp Status (IMPORTANT — read before wiring this engine into alignment)
///
/// **Voxtral-Mini-4B-Realtime-2602 does NOT expose word-level timestamps through
/// mlx-audio-swift v0.1.x.**
///
/// - The model internally marks word boundaries with `[W]` tokens at 80 ms frames,
///   but the library's decoder calls `skip_special_tokens=true`, discarding them.
/// - mlx-audio-swift v0.1.x returns only segment-level start/end times from the
///   streaming `generateStream()` path; no `words` array is populated.
/// - HuggingFace feature request for open word-timestamps remains open (research.md Q2).
/// - Extracting timestamps requires forking the decoder — not done here.
///
/// **Impact on this bake-off engine:**
/// - `transcribe(audioURL:options:)` returns `TranscriptSegment`s with empty `words` arrays.
/// - The alignment stage (Stage 4) requires word timestamps; if Voxtral wins the WER
///   bake-off you must either (a) build the custom `[W]`-token decoder or (b) run a
///   forced-aligner post-pass (Qwen3-ForcedAligner via mlx-audio-swift, Phase 4).
/// - Until timestamps are solved, **do NOT route Voxtral output to the Alignment stage**.
///
/// Source for this limitation: research.md D1, and inspection of VoxtralRealtimeDecoder.swift at
/// https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/VoxtralRealtime/VoxtralRealtimeDecoder.swift

import Foundation
import MLX
import MLXAudioCore
import MLXAudioSTT
import TatlinKit

/// Bake-off ASR engine backed by Voxtral-Mini-4B-Realtime-2602 (Apache-2.0, ~8.9 GB fp16).
///
/// **Word timestamps are NOT available** — see the module-level documentation above.
/// Only segment-level start/end times are returned.  Do not use this engine as the
/// alignment source until word-timestamp extraction is implemented.
@available(macOS 15, *)
public actor VoxtralEngine: ASREngine {

    // MARK: - ASREngine

    public nonisolated let modelID = "voxtral-mini-4b-realtime-2602"

    // MARK: - Private state

    private var model: VoxtralRealtimeModel?
    private let modelDirectory: URL

    // MARK: - Init

    public init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    // MARK: - Load / unload

    /// Load Voxtral-Mini-4B-Realtime weights from the pre-downloaded directory.
    ///
    /// VERIFY: `VoxtralRealtimeModel.fromDirectory(_:computeDType:)` — the Voxtral model
    /// class follows the same factory pattern as Parakeet in the same library.
    /// Source: https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/VoxtralRealtime/VoxtralRealtime.swift
    public func load() throws {
        guard model == nil else { return }
        // fromDirectory(_:) — synchronous throws, no computeDType in 0.1.2.
        // Source: .build/checkouts/mlx-audio-swift/Sources/MLXAudioSTT/Models/VoxtralRealtime/VoxtralRealtime.swift:377
        model = try VoxtralRealtimeModel.fromDirectory(modelDirectory)
    }

    public func unload() {
        model = nil
        MLX.GPU.clearCache()
    }

    // MARK: - ASREngine conformance

    /// Transcribe audio.  Returns segment-level timing; `words` arrays are always empty.
    ///
    /// - Note: If `options.wordTimestamps` is `true` this engine logs a warning and proceeds;
    ///   the caller (Stage 4 Alignment) must skip Voxtral output or wait for a future release
    ///   that exposes `[W]`-token timestamps.
    public func transcribe(audioURL: URL, options: ASROptions) async throws -> Transcript {
        guard let model else {
            throw ASRError.modelNotLoaded
        }

        if options.wordTimestamps {
            // Log rather than throw — the bake-off harness may still want WER scoring
            // even without alignment-compatible timestamps.
            print("[VoxtralEngine] WARNING: wordTimestamps requested but NOT available for " +
                  "Voxtral-Mini-4B-Realtime via mlx-audio-swift v0.1.x. " +
                  "Returning segment-level timing only. " +
                  "See VoxtralEngine.swift module comment for details.")
        }

        // Load audio at 16 kHz mono via the MLXAudioCore free function.
        // Source: .build/checkouts/mlx-audio-swift/Sources/MLXAudioCore/AudioUtils.swift:58
        let (_, samples) = try loadAudioArray(from: audioURL, sampleRate: 16000)

        // STTGenerateParameters.language is a non-optional String (default "English").
        // Source: .build/checkouts/mlx-audio-swift/Sources/MLXAudioSTT/Generation.swift:3
        let params = STTGenerateParameters(
            maxTokens: 8192,
            temperature: 0.0,
            language: options.languageHint ?? "English"
        )

        // Synchronous generate — same protocol as Parakeet.
        // Source: https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Generation.swift
        let output: STTOutput = model.generate(audio: samples, generationParameters: params)

        return mapToTranscript(output, languageHint: options.languageHint)
    }

    // MARK: - Private helpers

    private func mapToTranscript(_ output: STTOutput, languageHint: String?) -> Transcript {
        let language = output.language ?? languageHint

        guard let rawSegments = output.segments, !rawSegments.isEmpty else {
            let seg = TranscriptSegment(text: output.text, start: 0, end: 0, words: [])
            return Transcript(language: language, segments: [seg])
        }

        // segments are [[String: Any]] with keys "text"/"start"/"end"; word arrays stay empty
        // (Voxtral exposes no word timestamps — see module doc-comment).
        let tatlinSegments: [TranscriptSegment] = rawSegments.compactMap { dict in
            guard let text = dict["text"] as? String,
                  let start = dict["start"] as? Double,
                  let end = dict["end"] as? Double else { return nil }
            return TranscriptSegment(text: text, start: start, end: end, words: [])
        }

        return Transcript(language: language, segments: tatlinSegments)
    }
}
