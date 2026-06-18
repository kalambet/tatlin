import Foundation

/// The pipeline stages, in order. A session records which have completed so any stage
/// is independently re-runnable against the saved audio (plan.md crash-safety, Q7).
public enum PipelineStage: String, Codable, CaseIterable, Sendable {
    case capture
    case transcription
    case diarization
    case alignment
    case speakerID
    case summarization
    case output
}

/// On-disk session record (`session.json`). Created the instant the user clicks Start,
/// before audio flows, so the directory and metadata survive a crash.
public struct Session: Codable, Sendable {
    /// Sortable identifier, also the directory name, e.g. "2026-06-18T143000Z".
    public var id: String
    public var createdAt: Date
    public var endedAt: Date?
    /// Resolved display name: calendar event title when matched, else a timestamped default.
    public var title: String
    /// Calendar metadata when an event was matched at Start (plan.md ADR-13).
    public var event: EventSnapshot?
    /// Relative filenames within the session directory.
    public var systemAudioFile: String
    public var micAudioFile: String
    public var completedStages: Set<PipelineStage>

    public init(
        id: String,
        createdAt: Date,
        endedAt: Date? = nil,
        title: String,
        event: EventSnapshot? = nil,
        systemAudioFile: String = "raw-system.wav",
        micAudioFile: String = "raw-mic.wav",
        completedStages: Set<PipelineStage> = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.endedAt = endedAt
        self.title = title
        self.event = event
        self.systemAudioFile = systemAudioFile
        self.micAudioFile = micAudioFile
        self.completedStages = completedStages
    }
}

public extension Session {
    /// Default timestamped title when no calendar event matches (plan.md ADR-13).
    static func defaultTitle(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        return "Tatlin \(f.string(from: date))"
    }

    /// Sortable session id from a date, e.g. "2026-06-18T143000Z" (UTC, filename-safe).
    static func makeID(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        return f.string(from: date)
    }
}
