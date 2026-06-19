import Foundation

/// An action item extracted by the summarizer (plan.md M2.6).
public struct ActionItem: Codable, Sendable, Equatable {
    public var task: String
    /// Owner if inferable, matched against the calendar roster when present.
    public var owner: String?

    public init(task: String, owner: String? = nil) {
        self.task = task
        self.owner = owner
    }
}

/// A proposed mapping from an anonymous diarizer label to a real name, with the
/// evidence and confidence that gate whether it's applied (plan.md ADR-5, Q5).
public struct SpeakerNameProposal: Codable, Sendable, Equatable {
    public enum Confidence: String, Codable, Sendable { case high, medium, low }
    public var speakerLabel: String
    public var name: String
    public var evidence: String
    public var confidence: Confidence

    public init(speakerLabel: String, name: String, evidence: String, confidence: Confidence) {
        self.speakerLabel = speakerLabel
        self.name = name
        self.evidence = evidence
        self.confidence = confidence
    }
}

/// Structured result of Stage 6 (summarization). The Markdown body is authored by the
/// model under a fixed skeleton; the structured fields are parsed from a trailing block.
public struct MeetingNotes: Codable, Sendable {
    public var tldr: String
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var openQuestions: [String]
    public var perSpeakerHighlights: [String: [String]]
    public var speakerNameProposals: [SpeakerNameProposal]
    /// Language the notes were written in (resolved from the output-language setting).
    public var language: String?

    public init(
        tldr: String = "",
        decisions: [String] = [],
        actionItems: [ActionItem] = [],
        openQuestions: [String] = [],
        perSpeakerHighlights: [String: [String]] = [:],
        speakerNameProposals: [SpeakerNameProposal] = [],
        language: String? = nil
    ) {
        self.tldr = tldr
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.perSpeakerHighlights = perSpeakerHighlights
        self.speakerNameProposals = speakerNameProposals
        self.language = language
    }
}

/// A single chat-style turn for the LLM. Kept minimal and engine-agnostic.
public struct LLMMessage: Sendable {
    public enum Role: String, Sendable { case system, user, assistant }
    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// Sampling parameters for an ``LLMEngine`` (plan.md M2.6 defaults).
public struct LLMParameters: Sendable {
    public var temperature: Double
    public var topP: Double
    public var maxTokens: Int

    public init(temperature: Double = 0.3, topP: Double = 0.9, maxTokens: Int = 3000) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
    }
}

/// Stage 6 seam. Conformance: `QwenSummarizer` (Qwen3-30B-A3B via MLXLLM) in `TatlinML`.
public protocol LLMEngine: Sendable {
    var modelID: String { get }
    /// Run a chat completion and return the raw assistant text.
    func complete(messages: [LLMMessage], parameters: LLMParameters) async throws -> String
    /// Load model weights into memory before completion. Idempotent.
    func load() async throws
    /// Release model weights and reclaim memory.
    func unload() async
}
