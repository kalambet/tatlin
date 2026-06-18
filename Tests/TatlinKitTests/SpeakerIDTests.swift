import Foundation
import Testing
@testable import TatlinKit

@Suite("EnrollmentStore")
struct EnrollmentStoreTests {

    @Test("cosine similarity: identical vectors → 1, orthogonal → 0")
    func cosineBasics() {
        #expect(abs(EnrollmentStore.cosineSimilarity([1, 0, 0], [1, 0, 0]) - 1.0) < 1e-9)
        #expect(abs(EnrollmentStore.cosineSimilarity([1, 0], [0, 1])) < 1e-9)
        #expect(EnrollmentStore.cosineSimilarity([1, 0], [1, 0, 0]) == 0)  // length mismatch
        #expect(EnrollmentStore.cosineSimilarity([0, 0], [1, 1]) == 0)     // zero magnitude
    }

    @Test("bestMatch respects the threshold and picks the highest score")
    func bestMatchThreshold() {
        let db: [String: SpeakerEmbedding] = [
            "Anna": SpeakerEmbedding(vector: [1, 0, 0]),
            "Bob": SpeakerEmbedding(vector: [0.9, 0.1, 0]),
        ]
        let query = SpeakerEmbedding(vector: [1, 0, 0])
        let match = EnrollmentStore.bestMatch(for: query, in: db, threshold: 0.7)
        #expect(match?.name == "Anna")

        // Raise the bar above both → no match.
        let none = EnrollmentStore.bestMatch(for: SpeakerEmbedding(vector: [0, 0, 1]), in: db, threshold: 0.7)
        #expect(none == nil)
    }

    @Test("persistence round-trips through disk")
    func persistence() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tatlin-enroll-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = EnrollmentStore(root: root, threshold: 0.6)
        #expect(try store.load().isEmpty)
        try store.enroll(name: "Anna", embedding: SpeakerEmbedding(vector: [1, 0, 0]))
        let match = try store.bestMatch(for: SpeakerEmbedding(vector: [0.95, 0.05, 0]))
        #expect(match?.name == "Anna")
    }
}

@Suite("SpeakerResolver")
struct SpeakerResolverTests {

    private func transcript(labels: [String]) -> AlignedTranscript {
        let words = labels.enumerated().map { i, label in
            AttributedWord(word: Word(text: "w\(i)", start: Double(i), end: Double(i) + 1), speaker: label)
        }
        let segs = WordAligner.regroup(words)
        return AlignedTranscript(language: "en", words: words, segments: segs)
    }

    @Test("layer precedence: owner anchor wins over enrollment and LLM")
    func ownerWins() {
        let t = transcript(labels: ["Speaker 1", "Speaker 2"])
        let enrollment = ["Bob": SpeakerEmbedding(vector: [1, 0])]
        let embeddings = ["Speaker 1": SpeakerEmbedding(vector: [1, 0])]
        let proposals = [SpeakerNameProposal(speakerLabel: "Speaker 1", name: "Carol", evidence: "e", confidence: .high)]

        let r = SpeakerResolver.resolve(
            transcript: t, ownerLabel: "Speaker 1", ownerName: "You",
            embeddings: embeddings, enrollment: enrollment, threshold: 0.7,
            proposals: proposals, roster: [Attendee(name: "Carol")]
        )
        #expect(r.nameMap["Speaker 1"] == "You")  // owner anchor wins
    }

    @Test("enrollment layer names a matched embedding")
    func enrollmentLayer() {
        let t = transcript(labels: ["Speaker 1"])
        let r = SpeakerResolver.resolve(
            transcript: t, ownerLabel: nil,
            embeddings: ["Speaker 1": SpeakerEmbedding(vector: [1, 0])],
            enrollment: ["Anna": SpeakerEmbedding(vector: [1, 0])], threshold: 0.7
        )
        #expect(r.nameMap["Speaker 1"] == "Anna")
    }

    @Test("LLM confidence gating: high applied as inferred, low ignored")
    func confidenceGating() {
        let t = transcript(labels: ["Speaker 1", "Speaker 2"])
        let proposals = [
            SpeakerNameProposal(speakerLabel: "Speaker 1", name: "Anna", evidence: "e", confidence: .high),
            SpeakerNameProposal(speakerLabel: "Speaker 2", name: "Bob", evidence: "e", confidence: .low),
        ]
        let r = SpeakerResolver.resolve(
            transcript: t, ownerLabel: nil, proposals: proposals,
            roster: [Attendee(name: "Anna"), Attendee(name: "Bob")]
        )
        #expect(r.nameMap["Speaker 1"] == "Anna (inferred)")
        #expect(r.nameMap["Speaker 2"] == nil)  // low confidence left anonymous
    }

    @Test("roster constrains LLM names: off-roster high-confidence name is rejected")
    func rosterConstraint() {
        let t = transcript(labels: ["Speaker 1"])
        let proposals = [SpeakerNameProposal(speakerLabel: "Speaker 1", name: "Zelda", evidence: "e", confidence: .high)]
        let r = SpeakerResolver.resolve(
            transcript: t, ownerLabel: nil, proposals: proposals,
            roster: [Attendee(name: "Anna")]  // Zelda not on roster
        )
        #expect(r.nameMap["Speaker 1"] == nil)
    }
}
