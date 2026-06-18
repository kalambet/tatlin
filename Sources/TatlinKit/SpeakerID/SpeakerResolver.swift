import Foundation

/// Stage 5 (M2.5, ADR-5 / research Q5): layered relabel of an `AlignedTranscript`'s
/// anonymous "Speaker N" labels into real names, cheapest/most-reliable layer first:
///
///   1. **Owner anchor** — a deterministic label→owner-name mapping (the diarizer cluster
///      that best matched the mic channel, resolved upstream in the pipeline).
///   2. **Enrolled embeddings** — cosine match of each label's diarizer embedding against
///      the persistent speaker DB (research Q5 layer 2).
///   3. **LLM proposals** — `[SpeakerNameProposal]`, gated by confidence: `.high` applied
///      and rendered "Name (inferred)"; `.medium`/`.low` left as `Speaker N` (research Q5
///      layer 3, "never silently fabricate"). The calendar roster constrains/prefers LLM
///      names: a proposed name not on the roster is downgraded unless it is an exact match.
///
/// Earlier layers win: an owner-anchored or enrolled label is never overridden by the LLM.
public enum SpeakerResolver {

    /// Result of resolution: the relabeled transcript plus the final label→name map actually
    /// applied (labels with no confident name are absent from the map).
    public struct Resolution: Sendable {
        public var transcript: AlignedTranscript
        public var nameMap: [String: String]
        public init(transcript: AlignedTranscript, nameMap: [String: String]) {
            self.transcript = transcript
            self.nameMap = nameMap
        }
    }

    /// - Parameters:
    ///   - transcript:   Stage-4 aligned transcript (anonymous labels).
    ///   - ownerLabel:   Diarizer label resolved to the owner, or nil if unknown.
    ///   - ownerName:    Display name for the owner (default "You").
    ///   - embeddings:   Per-label diarizer embeddings (from `Diarization.embeddings`).
    ///   - enrollment:   In-memory enrollment DB (name → embedding). Pass `try store.load()`.
    ///   - threshold:    Cosine acceptance threshold for the enrollment layer.
    ///   - proposals:    LLM `speaker_name_map` proposals.
    ///   - roster:       Calendar attendees — names the LLM is preferred to map onto.
    public static func resolve(
        transcript: AlignedTranscript,
        ownerLabel: String?,
        ownerName: String = "You",
        embeddings: [String: SpeakerEmbedding] = [:],
        enrollment: [String: SpeakerEmbedding] = [:],
        threshold: Double = 0.7,
        proposals: [SpeakerNameProposal] = [],
        roster: [Attendee] = []
    ) -> Resolution {
        // Distinct labels present, in first-appearance order, so output is stable.
        var labels: [String] = []
        var seen = Set<String>()
        for w in transcript.words where !seen.contains(w.speaker) {
            seen.insert(w.speaker); labels.append(w.speaker)
        }

        var nameMap: [String: String] = [:]

        // Layer 1 — owner anchor (highest precedence).
        if let ownerLabel, labels.contains(ownerLabel) {
            nameMap[ownerLabel] = ownerName
        }

        // Layer 2 — enrolled embeddings (only labels not already owner-anchored).
        for label in labels where nameMap[label] == nil {
            guard let emb = embeddings[label] else { continue }
            if let match = EnrollmentStore.bestMatch(for: emb, in: enrollment, threshold: threshold) {
                nameMap[label] = match.name
            }
        }

        // Layer 3 — LLM proposals, confidence-gated, roster-constrained.
        let rosterNames = Set(roster.map { $0.name })
        // First proposal per label wins; only high-confidence proposals are eligible.
        for proposal in proposals where proposal.confidence == .high {
            let label = proposal.speakerLabel
            guard labels.contains(label), nameMap[label] == nil else { continue }
            // Roster gate: if a roster exists, only accept names on it (exact match).
            if !rosterNames.isEmpty && !rosterNames.contains(proposal.name) { continue }
            nameMap[label] = "\(proposal.name) (inferred)"
        }

        // Apply the map; unmapped labels keep their anonymous name.
        let words = transcript.words.map { aw -> AttributedWord in
            var copy = aw
            if let name = nameMap[aw.speaker] { copy.speaker = name }
            return copy
        }
        let segments = transcript.segments.map { seg -> AttributedSegment in
            var copy = seg
            if let name = nameMap[seg.speaker] { copy.speaker = name }
            return copy
        }

        let relabeled = AlignedTranscript(language: transcript.language, words: words, segments: segments)
        return Resolution(transcript: relabeled, nameMap: nameMap)
    }
}
