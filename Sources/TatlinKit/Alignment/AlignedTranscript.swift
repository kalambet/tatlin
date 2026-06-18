import Foundation

/// A word after speaker attribution (Stage 4). `overlap` marks words that fell in a
/// region where the diarizer reported ≥2 simultaneous speakers (plan.md Q4) — rendered
/// low-confidence downstream.
public struct AttributedWord: Codable, Sendable, Equatable {
    public var word: Word
    /// Resolved speaker label (anonymous "Speaker N" or a real name once identified).
    public var speaker: String
    public var overlap: Bool

    public init(word: Word, speaker: String, overlap: Bool = false) {
        self.word = word
        self.speaker = speaker
        self.overlap = overlap
    }
}

/// Consecutive attributed words by a single speaker, regrouped for display/output.
public struct AttributedSegment: Codable, Sendable, Equatable {
    public var speaker: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var overlap: Bool

    public init(speaker: String, start: TimeInterval, end: TimeInterval, text: String, overlap: Bool = false) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.overlap = overlap
    }
}

/// Output of Stage 4 (alignment): the speaker-attributed transcript that Stages 5–7 consume.
public struct AlignedTranscript: Codable, Sendable {
    public var language: String?
    public var words: [AttributedWord]
    public var segments: [AttributedSegment]

    public init(language: String? = nil, words: [AttributedWord], segments: [AttributedSegment]) {
        self.language = language
        self.words = words
        self.segments = segments
    }
}
