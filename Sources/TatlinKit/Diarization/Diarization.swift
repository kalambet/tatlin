import Foundation

/// A speaker embedding vector (FluidAudio exposes these per-speaker/per-chunk).
/// Used for enrollment and cross-meeting identity matching (plan.md ADR-5).
public struct SpeakerEmbedding: Codable, Sendable, Equatable {
    public var vector: [Float]

    public init(vector: [Float]) {
        self.vector = vector
    }
}

/// A contiguous interval attributed to one (anonymous) diarizer speaker label.
public struct SpeakerTurn: Codable, Sendable, Equatable {
    /// Anonymous label from the diarizer, e.g. "Speaker 1".
    public var speaker: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(speaker: String, start: TimeInterval, end: TimeInterval) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// Output of Stage 3 (diarization). Overlap is represented by turns whose intervals
/// intersect — the alignment stage flags those regions low-confidence (plan.md Q4).
public struct Diarization: Codable, Sendable {
    public var turns: [SpeakerTurn]
    /// Per-speaker representative embedding, keyed by anonymous label, when available.
    public var embeddings: [String: SpeakerEmbedding]

    public init(turns: [SpeakerTurn], embeddings: [String: SpeakerEmbedding] = [:]) {
        self.turns = turns
        self.embeddings = embeddings
    }

    /// Distinct anonymous speaker labels, in first-appearance order.
    public var speakerLabels: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for turn in turns.sorted(by: { $0.start < $1.start }) where !seen.contains(turn.speaker) {
            seen.insert(turn.speaker)
            ordered.append(turn.speaker)
        }
        return ordered
    }
}

/// Stage 3 seam. Conformance: `FluidDiarizer` (FluidAudio community-1) in `TatlinML`.
public protocol DiarizerEngine: Sendable {
    var modelID: String { get }
    /// Diarize a 16 kHz mono audio file into speaker turns (+ embeddings when supported).
    func diarize(audioURL: URL) async throws -> Diarization
}
