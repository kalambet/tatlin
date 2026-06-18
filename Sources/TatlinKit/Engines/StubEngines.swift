import Foundation

/// Deterministic, dependency-free fakes for the three pipeline engine seams (ASR /
/// diarizer / LLM). They let `BatchPipeline` run end-to-end with no MLX/FluidAudio deps,
/// so Stages 2–7 are testable offline and the `tatlin run` CLI works before TatlinML is
/// enabled (plan.md ADR-10, M2.8). The concrete engines live in the separate TatlinML target.

// MARK: - ASR

/// Returns a small canned two-speaker `Transcript` with word timestamps. The timings are
/// chosen so the diarizer stub's turns align cleanly and produce a mid-segment switch.
public struct StubASREngine: ASREngine {
    public let modelID = "stub-asr"
    public let language: String

    public init(language: String = "en") { self.language = language }

    public func transcribe(audioURL: URL, options: ASROptions) async throws -> Transcript {
        func word(_ t: String, _ s: TimeInterval, _ e: TimeInterval) -> Word {
            Word(text: t, start: s, end: e, confidence: 0.95)
        }
        // 0–4s speaker 1, 4–8s speaker 2 (see StubDiarizer turns).
        let s1 = TranscriptSegment(
            text: "Welcome everyone let's begin",
            start: 0.0, end: 4.0,
            words: [word("Welcome", 0.0, 1.0), word("everyone", 1.0, 2.0),
                    word("let's", 2.0, 3.0), word("begin", 3.0, 4.0)]
        )
        let s2 = TranscriptSegment(
            text: "Thanks Anna I'll take notes",
            start: 4.0, end: 8.0,
            words: [word("Thanks", 4.0, 5.0), word("Anna", 5.0, 6.0),
                    word("I'll", 6.0, 7.0), word("notes", 7.0, 8.0)]
        )
        return Transcript(language: language, segments: [s1, s2])
    }
}

// MARK: - Diarizer

/// Two non-overlapping turns plus per-label embeddings. Label "Speaker 1" leads (0–4s),
/// "Speaker 2" follows (4–8s); embeddings are unit-ish vectors so cosine math is exercised.
public struct StubDiarizer: DiarizerEngine {
    public let modelID = "stub-diarizer"
    public init() {}

    public func diarize(audioURL: URL) async throws -> Diarization {
        let turns = [
            SpeakerTurn(speaker: "Speaker 1", start: 0.0, end: 4.0),
            SpeakerTurn(speaker: "Speaker 2", start: 4.0, end: 8.0),
        ]
        let embeddings: [String: SpeakerEmbedding] = [
            "Speaker 1": SpeakerEmbedding(vector: [1, 0, 0, 0]),
            "Speaker 2": SpeakerEmbedding(vector: [0, 1, 0, 0]),
        ]
        return Diarization(turns: turns, embeddings: embeddings)
    }
}

// MARK: - LLM

/// Returns a canned structured-Markdown completion (including the trailing ```json
/// speaker_name_map block) that `NotesParser` parses cleanly. Ignores the prompt content;
/// deterministic for tests.
public struct StubLLMEngine: LLMEngine {
    public let modelID = "stub-llm"
    public init() {}

    public func complete(messages: [LLMMessage], parameters: LLMParameters) async throws -> String {
        """
        ## TL;DR
        - The team kicked off the meeting and assigned note-taking.

        ## Key Decisions
        - Anna will take the meeting notes.

        ## Action Items
        - [ ] Take meeting notes — **owner:** Anna
        - [ ] Schedule the follow-up — **owner:** unassigned

        ## Open Questions
        - _None_

        ## Per-Speaker Highlights
        ### Speaker 1
        - Opened the meeting.
        ### Speaker 2
        - Offered to take notes.

        ```json
        [{"speakerLabel":"Speaker 2","name":"Anna","evidence":"addressed as 'Thanks Anna'","confidence":"high"}]
        ```
        """
    }
}
