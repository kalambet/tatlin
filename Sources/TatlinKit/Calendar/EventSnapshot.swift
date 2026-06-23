import Foundation

/// A meeting participant pulled from a calendar event. Used both as display metadata
/// and as a naming prior for speaker identification (plan.md ADR-5/ADR-13).
public struct Attendee: Codable, Sendable, Hashable {
    public var name: String
    public var email: String?

    public init(name: String, email: String? = nil) {
        self.name = name
        self.email = email
    }
}

/// Read-only snapshot of the calendar event that was active when capture started
/// (plan.md ADR-13). Never drives automation — it only enriches the session.
public struct EventSnapshot: Codable, Sendable {
    /// Stable EventKit identifier (`EKEvent.eventIdentifier`), if available.
    public var eventIdentifier: String?
    /// Recurring-series identity (`EKEvent.calendarItemExternalIdentifier`), set only when the
    /// event recurs — identical across every instance, so it groups a series (M3.9 / ADR-14).
    /// nil for one-off events, which fall back to title-based grouping.
    public var seriesID: String?
    public var title: String
    public var attendees: [Attendee]
    public var notes: String?
    public var startDate: Date?
    public var endDate: Date?
    /// Title of the source calendar (e.g. "Work", "Personal").
    public var calendarTitle: String?

    public init(
        eventIdentifier: String? = nil,
        seriesID: String? = nil,
        title: String,
        attendees: [Attendee] = [],
        notes: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        calendarTitle: String? = nil
    ) {
        self.eventIdentifier = eventIdentifier
        self.seriesID = seriesID
        self.title = title
        self.attendees = attendees
        self.notes = notes
        self.startDate = startDate
        self.endDate = endDate
        self.calendarTitle = calendarTitle
    }
}
