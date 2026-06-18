// FluidDiarizer.swift — TatlinML
//
// Concrete DiarizerEngine backed by FluidAudio OfflineDiarizerManager (community-1 pipeline).
//
// Source references:
//   Protocol contract:   Sources/TatlinKit/Diarization/Diarization.swift
//   OfflineDiarizerManager (class, init, prepareModels, process):
//     https://github.com/FluidInference/FluidAudio/blob/main/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerManager.swift
//   DiarizationResult (segments, chunkEmbeddings):
//     https://github.com/FluidInference/FluidAudio/blob/main/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerManager.swift
//   Diarizer protocol (processComplete with URL):
//     https://github.com/FluidInference/FluidAudio/blob/main/Sources/FluidAudio/Diarizer/DiarizerProtocol.swift
//   DiarizerSegment (startTime, endTime, speakerId):
//     https://github.com/FluidInference/FluidAudio/blob/main/Sources/FluidAudio/Diarizer/DiarizerTimeline.swift
//   ChunkEmbedding (speakerId, embedding256):
//     https://github.com/FluidInference/FluidAudio/blob/main/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerManager.swift
//   OfflineDiarizerConfig (.default, exposeChunkEmbeddings):
//     https://github.com/FluidInference/FluidAudio/blob/main/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerManager.swift
//   Licensing note: pyannote community-1 is CC-BY-4.0, gated on HF; attribute in-app.
//     See plan.md ADR-3 / research.md Q3.

import Foundation
import FluidAudio
import TatlinKit

/// Diarizer backed by FluidAudio's `OfflineDiarizerManager` → pyannote community-1 pipeline
/// (powerset segmentation + WeSpeaker embeddings + VBx clustering, all CoreML/ANE).
///
/// **Licensing:** The underlying pyannote speaker-diarization-community-1 weights are
/// CC-BY-4.0 and gated on Hugging Face.  The app must display attribution and the user
/// must accept the license before first download.  (plan.md ADR-3, research.md Q3.)
///
/// **Speaker embedding export:** `exposeChunkEmbeddings = true` is set in config so
/// `DiarizationResult.chunkEmbeddings` is populated.  We aggregate per-speaker embeddings
/// by averaging the 256-d vectors for each speaker cluster, then store them in
/// `Diarization.embeddings` for the SpeakerID enrollment stage.
///
/// **VERIFY (priority):**
/// - `OfflineDiarizerConfig.default` exists and has `exposeChunkEmbeddings: Bool` field.
///   Source: https://github.com/FluidInference/FluidAudio/blob/main/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerManager.swift
/// - `DiarizationResult.segments` element type has `speakerId: String`, `startTimeSeconds: Float`,
///   `endTimeSeconds: Float` properties (confirmed from README example + code inspection).
///   Source: https://github.com/FluidInference/FluidAudio/blob/main/README.md
/// - `DiarizationResult.chunkEmbeddings?: [ChunkEmbedding]` where `ChunkEmbedding` has
///   `speakerId: String` and `embedding256: [Float]` (confirmed from code inspection).
///   Source: https://github.com/FluidInference/FluidAudio/blob/main/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerManager.swift
@available(macOS 15, *)
public final class FluidDiarizer: DiarizerEngine, @unchecked Sendable {

    // MARK: - DiarizerEngine

    public let modelID = "speaker-diarization-community-1"

    // MARK: - Private state

    // A reference-type wrapper (not an actor) around FluidAudio's non-Sendable
    // `OfflineDiarizerManager`, whose `process(_:)` is async — awaiting it from an actor
    // trips Swift 6's "sending non-Sendable value" check. `ModelHost` guarantees single,
    // serialized residency, so `@unchecked Sendable` with no internal locking is safe here.
    private var manager: OfflineDiarizerManager?
    private let modelDirectory: URL?

    // MARK: - Init

    /// - Parameter modelDirectory: Optional override; when `nil` FluidAudio downloads models
    ///   to its own default cache.  Pass the `ModelStore` directory to control placement.
    public init(modelDirectory: URL? = nil) {
        self.modelDirectory = modelDirectory
    }

    // MARK: - Load / unload

    /// Prepare the FluidAudio CoreML models (download + compile if needed).
    ///
    /// `prepareModels(directory:configuration:forceRedownload:)` is `async throws`.
    /// Source: https://github.com/FluidInference/FluidAudio/blob/main/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerManager.swift
    public func load() async throws {
        guard manager == nil else { return }

        // Default offline config (community-1 pipeline). Per-speaker embeddings come from
        // `DiarizationResult.speakerDatabase`, which offline pipelines populate regardless.
        // Source: .build/checkouts/FluidAudio/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerTypes.swift:33
        let config = OfflineDiarizerConfig()
        let m = OfflineDiarizerManager(config: config)

        // prepareModels downloads/compiles CoreML models.
        // Pass our ModelStore directory so downloads land in Application Support.
        // Source: https://github.com/FluidInference/FluidAudio/blob/main/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerManager.swift
        try await m.prepareModels(directory: modelDirectory)

        manager = m
    }

    public func unload() {
        manager = nil
    }

    // MARK: - DiarizerEngine conformance

    /// Diarize a 16 kHz mono audio file, returning speaker turns and per-speaker embeddings.
    ///
    /// The file is passed directly to FluidAudio's file-URL API which handles its own
    /// memory-mapped streaming; no in-memory load needed.
    ///
    /// Source for process(_ url:progressCallback:):
    ///   https://github.com/FluidInference/FluidAudio/blob/main/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerManager.swift
    public func diarize(audioURL: URL) async throws -> Diarization {
        guard let manager else {
            throw DiarizationError.modelNotLoaded
        }

        // process(_:progressCallback:) — memory-mapped file-based path, async throws.
        // Returns DiarizationResult containing segments + optional chunkEmbeddings.
        // Source: https://github.com/FluidInference/FluidAudio/blob/main/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerManager.swift
        let result: DiarizationResult = try await manager.process(audioURL)

        return mapToDiarization(result)
    }

    // MARK: - Private helpers

    private func mapToDiarization(_ result: DiarizationResult) -> Diarization {
        // --- Speaker turns ---
        // DiarizationResult.segments: [TimedSpeakerSegment] with speakerId/startTimeSeconds/
        //   endTimeSeconds (Float) + embedding ([Float]).
        // Source: .build/checkouts/FluidAudio/Sources/FluidAudio/Diarizer/Core/DiarizerTypes.swift:161,191
        let turns: [SpeakerTurn] = result.segments.map { seg in
            SpeakerTurn(
                speaker: seg.speakerId,
                start: TimeInterval(seg.startTimeSeconds),
                end: TimeInterval(seg.endTimeSeconds)
            )
        }

        // --- Per-speaker embeddings ---
        // Offline pipelines populate `speakerDatabase: [String: [Float]]?` directly
        // (speakerId → representative embedding). Use it when present, else fall back to
        // averaging per-segment embeddings.
        // Source: .build/checkouts/FluidAudio/Sources/FluidAudio/Diarizer/Core/DiarizerTypes.swift:164
        var embeddings: [String: SpeakerEmbedding] = [:]
        if let db = result.speakerDatabase {
            for (speaker, vec) in db {
                embeddings[speaker] = SpeakerEmbedding(vector: vec)
            }
        } else {
            var sums: [String: (sum: [Double], count: Int)] = [:]
            for seg in result.segments where !seg.embedding.isEmpty {
                let vec = seg.embedding.map(Double.init)
                if var existing = sums[seg.speakerId] {
                    for i in 0 ..< min(vec.count, existing.sum.count) { existing.sum[i] += vec[i] }
                    existing.count += 1
                    sums[seg.speakerId] = existing
                } else {
                    sums[seg.speakerId] = (sum: vec, count: 1)
                }
            }
            for (speaker, acc) in sums {
                let c = Double(acc.count)
                embeddings[speaker] = SpeakerEmbedding(vector: acc.sum.map { Float($0 / c) })
            }
        }

        return Diarization(turns: turns, embeddings: embeddings)
    }
}

// MARK: - Errors

public enum DiarizationError: Error, Sendable {
    case modelNotLoaded
}
