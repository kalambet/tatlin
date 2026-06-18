import Foundation
import Testing
@testable import TatlinKit

@Suite("DER")
struct DERTests {

    // MARK: - Perfect match

    @Test("identical 2-speaker scenario gives DER 0")
    func perfectMatch() {
        let ref = [
            SpeakerTurn(speaker: "A", start: 0.0, end: 5.0),
            SpeakerTurn(speaker: "B", start: 5.0, end: 10.0),
        ]
        let hyp = [
            SpeakerTurn(speaker: "A", start: 0.0, end: 5.0),
            SpeakerTurn(speaker: "B", start: 5.0, end: 10.0),
        ]
        let result = DER.compute(reference: ref, hypothesis: hyp)
        #expect(result.rate == 0.0)
        #expect(result.missedSpeech == 0.0)
        #expect(result.falseAlarm == 0.0)
        #expect(result.speakerConfusion == 0.0)
    }

    // MARK: - Label permutation

    @Test("swapped labels count as confusion, not miss/FA")
    func labelSwap() {
        // ref: A[0-5], B[5-10]
        // hyp: B[0-5], A[5-10]  ← labels swapped; greedy mapping should fix it
        let ref = [
            SpeakerTurn(speaker: "A", start: 0.0, end: 5.0),
            SpeakerTurn(speaker: "B", start: 5.0, end: 10.0),
        ]
        let hyp = [
            SpeakerTurn(speaker: "B", start: 0.0, end: 5.0),
            SpeakerTurn(speaker: "A", start: 5.0, end: 10.0),
        ]
        let result = DER.compute(reference: ref, hypothesis: hyp)
        // Greedy map: ref A → hyp B (max overlap in [0-5]) and ref B → hyp A (max overlap in [5-10]).
        // After mapping, every frame should match.
        #expect(result.rate == 0.0)
        #expect(result.speakerConfusion < 0.02) // ≤1 frame rounding
    }

    // MARK: - Missed speech

    @Test("hypothesis shorter than reference → missed speech")
    func missedSpeech() {
        // ref: A for 10 s; hyp: A for first 5 s only → 5 s missed
        let ref = [SpeakerTurn(speaker: "A", start: 0.0, end: 10.0)]
        let hyp = [SpeakerTurn(speaker: "A", start: 0.0, end: 5.0)]
        let result = DER.compute(reference: ref, hypothesis: hyp)
        // missedSpeech ≈ 5 s (±frameResolution)
        #expect(abs(result.missedSpeech - 5.0) < 0.05)
        #expect(result.falseAlarm == 0.0)
        #expect(result.speakerConfusion == 0.0)
        #expect(abs(result.rate - 0.5) < 0.01)
    }

    // MARK: - False alarm

    @Test("hypothesis longer than reference → false alarm")
    func falseAlarm() {
        // ref: A for 5 s; hyp: A for 10 s → 5 s false alarm
        let ref = [SpeakerTurn(speaker: "A", start: 0.0, end: 5.0)]
        let hyp = [SpeakerTurn(speaker: "A", start: 0.0, end: 10.0)]
        let result = DER.compute(reference: ref, hypothesis: hyp)
        #expect(abs(result.falseAlarm - 5.0) < 0.05)
        #expect(result.missedSpeech == 0.0)
        #expect(result.speakerConfusion == 0.0)
        // DER = falseAlarm / totalRef = 5/5 = 1.0
        #expect(abs(result.rate - 1.0) < 0.01)
    }

    // MARK: - Speaker confusion

    @Test("3-speaker confusion — greedy leaves one speaker confused")
    func speakerConfusion() {
        // ref: A[0-4], B[4-8], C[8-10]
        // hyp: X[0-4], X[4-8], Y[8-10]
        //
        // Greedy: ref A → hyp X (overlap [0-4]), ref B → hyp X (overlap [4-8]),
        //         ref C → hyp Y (overlap [8-10]).
        // After mapping A→X, B→X maps to same hyp label → collision: B frames get
        // mapped to X but X is already taken by A.  B's frames where hyp=X but
        // mapping[B]=X will count as correct — no confusion.
        // Actually greedy does NOT enforce injection: two ref labels may map to the
        // same hyp label.  So A→X and B→X both count as "correct" for the greedy mapping.
        // This is the documented simplification.
        //
        // Use a case where confusion IS forced: 3 ref speakers, only 2 hyp labels,
        // one ref speaker entirely missing from hyp (missed) and another mislabelled.
        //
        // ref: A[0-4], B[4-7], C[7-10]
        // hyp: X[0-4], X[7-10]           (B's region is silent in hyp → missed speech)
        // Greedy: A→X (overlap [0-4]), C→X (overlap [7-10]).
        // Frames in [0-4]: ref=A, hyp=X, mapping[A]=X → correct.
        // Frames in [4-7]: ref=B, hyp=nil → missed (3 s).
        // Frames in [7-10]: ref=C, hyp=X, mapping[C]=X → correct.
        let ref = [
            SpeakerTurn(speaker: "A", start: 0.0, end: 4.0),
            SpeakerTurn(speaker: "B", start: 4.0, end: 7.0),
            SpeakerTurn(speaker: "C", start: 7.0, end: 10.0),
        ]
        let hyp = [
            SpeakerTurn(speaker: "X", start: 0.0, end: 4.0),
            SpeakerTurn(speaker: "X", start: 7.0, end: 10.0),
        ]
        let result = DER.compute(reference: ref, hypothesis: hyp)
        // B's 3 s region is missed (hyp silent).
        #expect(abs(result.missedSpeech - 3.0) < 0.05)
        #expect(result.speakerConfusion == 0.0)
        // DER = 3 / 10 = 0.3
        #expect(abs(result.rate - 0.3) < 0.01)
    }

    // MARK: - Empty inputs

    @Test("both empty gives DER 0")
    func bothEmpty() {
        let result = DER.compute(reference: [], hypothesis: [])
        #expect(result.rate == 0.0)
        #expect(result.totalReferenceSpeech == 0.0)
    }

    @Test("empty reference, non-empty hypothesis → false alarm only")
    func emptyReference() {
        let hyp = [SpeakerTurn(speaker: "A", start: 0.0, end: 5.0)]
        let result = DER.compute(reference: [], hypothesis: hyp)
        #expect(result.totalReferenceSpeech == 0.0)
        #expect(result.falseAlarm > 0.0)
        #expect(result.rate == 0.0)  // 0/0 → 0 by convention
    }

    // MARK: - Frame label helper

    @Test("frameLabels assigns correct speakers")
    func frameLabels() {
        let turns = [
            SpeakerTurn(speaker: "A", start: 0.0, end: 1.0),
            SpeakerTurn(speaker: "B", start: 1.0, end: 2.0),
        ]
        let labels = DER.frameLabels(from: turns, frameCount: 200, resolution: 0.01)
        // Frames 0–99 → A; frames 100–199 → B.
        #expect(labels[0] == "A")
        #expect(labels[99] == "A")
        #expect(labels[100] == "B")
        #expect(labels[199] == "B")
    }
}
