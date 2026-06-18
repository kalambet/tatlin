import Foundation
import Testing
@testable import TatlinKit

@Suite("WordAligner")
struct WordAlignerTests {

    private func word(_ t: String, _ s: TimeInterval, _ e: TimeInterval) -> Word {
        Word(text: t, start: s, end: e)
    }

    private func transcript(_ words: [Word]) -> Transcript {
        let seg = TranscriptSegment(
            text: words.map(\.text).joined(separator: " "),
            start: words.first?.start ?? 0, end: words.last?.end ?? 0, words: words
        )
        return Transcript(language: "en", segments: [seg])
    }

    @Test("clean assignment: each word maps to its containing turn")
    func cleanAssignment() {
        let t = transcript([word("a", 0, 1), word("b", 1, 2), word("c", 4, 5)])
        let d = Diarization(turns: [
            SpeakerTurn(speaker: "S1", start: 0, end: 3),
            SpeakerTurn(speaker: "S2", start: 3, end: 6),
        ])
        let aligned = WordAligner.align(transcript: t, diarization: d)
        #expect(aligned.words.map(\.speaker) == ["S1", "S1", "S2"])
        #expect(aligned.words.allSatisfy { !$0.overlap })
        // Regrouped into two segments.
        #expect(aligned.segments.map(\.speaker) == ["S1", "S2"])
    }

    @Test("mid-segment speaker switch: word-level reassignment")
    func midSegmentSwitch() {
        // A single ASR segment whose words straddle a turn boundary at t=2.
        let t = transcript([word("one", 0, 1), word("two", 1, 1.9), word("three", 2.1, 3), word("four", 3, 4)])
        let d = Diarization(turns: [
            SpeakerTurn(speaker: "S1", start: 0, end: 2),
            SpeakerTurn(speaker: "S2", start: 2, end: 4),
        ])
        let aligned = WordAligner.align(transcript: t, diarization: d)
        #expect(aligned.words.map(\.speaker) == ["S1", "S1", "S2", "S2"])
        #expect(aligned.segments.count == 2)
    }

    @Test("overlap region: word touching ≥2 active turns is flagged")
    func overlapFlagged() {
        // Word [1,2] overlaps both S1 [0,1.5] and S2 [1.5,3].
        let t = transcript([word("x", 1, 2)])
        let d = Diarization(turns: [
            SpeakerTurn(speaker: "S1", start: 0, end: 1.5),
            SpeakerTurn(speaker: "S2", start: 1.5, end: 3),
        ])
        let aligned = WordAligner.align(transcript: t, diarization: d)
        #expect(aligned.words.first?.overlap == true)
    }

    @Test("owner precedence overrides the diarizer within owner intervals")
    func ownerPrecedence() {
        let t = transcript([word("hi", 0, 1), word("there", 5, 6)])
        let d = Diarization(turns: [SpeakerTurn(speaker: "S1", start: 0, end: 10)])
        // Owner spoke during [0,1] — force that word to "Owner".
        let owner = [WordAligner.Interval(start: 0, end: 1)]
        let aligned = WordAligner.align(transcript: t, diarization: d, ownerIntervals: owner, ownerLabel: "Owner")
        #expect(aligned.words.map(\.speaker) == ["Owner", "S1"])
    }

    @Test("no-overlap word falls back to the nearest turn")
    func nearestFallback() {
        let t = transcript([word("gap", 10, 11)])
        let d = Diarization(turns: [
            SpeakerTurn(speaker: "S1", start: 0, end: 2),
            SpeakerTurn(speaker: "S2", start: 8, end: 9),  // nearest to t≈10.5
        ])
        let aligned = WordAligner.align(transcript: t, diarization: d)
        #expect(aligned.words.first?.speaker == "S2")
    }
}
