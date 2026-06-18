import Foundation

/// Persistent speaker enrollment DB (M2.5, research Q5 layer 2). Maps a real name to a
/// representative `SpeakerEmbedding`, stored as `<SessionStore.root>/speakers.json`.
///
/// Matching is cosine similarity against an injectable threshold; near-misses return nil so
/// unknowns stay anonymous (conservative by design — research Q5 "treat near-misses as
/// unknown"). The cosine math is pure and unit-tested.
public struct EnrollmentStore: Sendable {
    /// `<root>/speakers.json`
    public let fileURL: URL
    /// Cosine-similarity acceptance threshold (FluidAudio's value is unpublished — set
    /// empirically in Phase 1B; default is a conservative prior, plan.md Part F #4).
    public let threshold: Double

    public init(root: URL, threshold: Double = 0.7) {
        self.fileURL = root.appendingPathComponent("speakers.json", isDirectory: false)
        self.threshold = threshold
    }

    /// Convenience initializer pinned to a `SessionStore`'s root.
    public init(store: SessionStore, threshold: Double = 0.7) {
        self.init(root: store.root, threshold: threshold)
    }

    // MARK: - Persistence

    /// All enrolled profiles, name → embedding. Empty if the file is absent.
    public func load() throws -> [String: SpeakerEmbedding] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([String: SpeakerEmbedding].self, from: data)
    }

    /// Replace the entire DB on disk (atomic write).
    public func save(_ profiles: [String: SpeakerEmbedding]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profiles)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Enroll (or update) one profile and persist. Self-improving loop (research Q5).
    public func enroll(name: String, embedding: SpeakerEmbedding) throws {
        var profiles = try load()
        profiles[name] = embedding
        try save(profiles)
    }

    // MARK: - Matching

    /// Best enrolled match for `embedding` at or above `threshold`, else nil.
    /// Deterministic on ties via name ordering.
    public func bestMatch(for embedding: SpeakerEmbedding) throws -> (name: String, score: Double)? {
        Self.bestMatch(for: embedding, in: try load(), threshold: threshold)
    }

    /// Pure matcher over an in-memory DB (unit-tested without touching disk).
    public static func bestMatch(
        for embedding: SpeakerEmbedding,
        in profiles: [String: SpeakerEmbedding],
        threshold: Double
    ) -> (name: String, score: Double)? {
        var best: (name: String, score: Double)?
        for (name, profile) in profiles {
            let score = cosineSimilarity(embedding.vector, profile.vector)
            guard score >= threshold else { continue }
            if let b = best {
                if score > b.score || (score == b.score && name < b.name) {
                    best = (name, score)
                }
            } else {
                best = (name, score)
            }
        }
        return best
    }

    /// Cosine similarity of two equal-length vectors. Returns 0 for empty/length-mismatched
    /// vectors or a zero-magnitude operand (undefined → treated as "no match").
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            let x = Double(a[i]), y = Double(b[i])
            dot += x * y
            na += x * x
            nb += y * y
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}
