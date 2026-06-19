import Foundation

/// A single recognized word with timing, the alignment join key against speaker turns
/// (plan.md ADR-4). Word-level timestamps are a hard requirement on the ASR engine.
public struct Word: Codable, Sendable, Equatable {
    public var text: String
    /// Start time in seconds from the start of the audio.
    public var start: TimeInterval
    /// End time in seconds from the start of the audio.
    public var end: TimeInterval
    public var confidence: Double?

    public init(text: String, start: TimeInterval, end: TimeInterval, confidence: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

/// A coarse transcript segment (sentence/utterance) as emitted by the ASR engine,
/// before speaker reassignment. Carries its words for word-level alignment.
public struct TranscriptSegment: Codable, Sendable, Equatable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var words: [Word]

    public init(text: String, start: TimeInterval, end: TimeInterval, words: [Word] = []) {
        self.text = text
        self.start = start
        self.end = end
        self.words = words
    }
}

/// Output of Stage 2 (transcription). `language` is the detected dominant language
/// (BCP-47-ish), used to drive the "Match meeting" output-language setting (plan.md M2.6).
public struct Transcript: Codable, Sendable {
    public var language: String?
    public var segments: [TranscriptSegment]
    /// Convenience: every word across all segments, in time order.
    public var words: [Word] { segments.flatMap(\.words) }

    public init(language: String? = nil, segments: [TranscriptSegment]) {
        self.language = language
        self.segments = segments
    }
}

/// Options passed to an ``ASREngine``.
public struct ASROptions: Sendable {
    /// Optional language hint (nil = auto-detect / multilingual).
    public var languageHint: String?
    /// Request word-level timestamps (required for alignment; engines must honor it).
    public var wordTimestamps: Bool

    public init(languageHint: String? = nil, wordTimestamps: Bool = true) {
        self.languageHint = languageHint
        self.wordTimestamps = wordTimestamps
    }
}

/// Stage 2 seam. Conformances: `ParakeetEngine` (primary), `VoxtralEngine` (bake-off),
/// `WhisperKitEngine` (fallback) — all in the `TatlinML` target.
public protocol ASREngine: Sendable {
    /// Short identifier for eval/reporting (e.g. "parakeet-tdt-0.6b-v3").
    var modelID: String { get }
    /// Transcribe a 16 kHz mono audio file to words+timestamps.
    func transcribe(audioURL: URL, options: ASROptions) async throws -> Transcript
    /// Load model weights into memory before transcription. Idempotent.
    func load() async throws
    /// Release model weights and reclaim memory.
    func unload() async
}
