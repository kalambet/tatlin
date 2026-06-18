import EventKit
import Foundation

// MARK: - Candidate model (testable, no EventKit dependency)

/// Lightweight representation of a calendar event used by the pure-logic filter and
/// resolution functions. Keeps EventKit glue thin and the logic independently testable.
public struct CandidateEvent: Sendable {
    public var identifier: String
    public var title: String
    public var isAllDay: Bool
    public var availability: EKEventAvailability
    public var startDate: Date
    public var endDate: Date
    public var attendees: [Attendee]
    public var notes: String?
    public var calendarTitle: String?

    public init(
        identifier: String,
        title: String,
        isAllDay: Bool,
        availability: EKEventAvailability,
        startDate: Date,
        endDate: Date,
        attendees: [Attendee] = [],
        notes: String? = nil,
        calendarTitle: String? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.isAllDay = isAllDay
        self.availability = availability
        self.startDate = startDate
        self.endDate = endDate
        self.attendees = attendees
        self.notes = notes
        self.calendarTitle = calendarTitle
    }
}

// MARK: - Skip-list filter (pure, testable)

/// Default titles that indicate non-meeting blocks (plan.md ADR-13).
public let defaultSkipList: [String] = [
    "Out of Office", "OOO", "Focus Time", "Focus", "Busy"
]

/// Returns `true` if the event should be excluded from meeting candidates.
///
/// Excluded when:
/// - `isAllDay` is true, **or**
/// - availability is `.free` or `.unavailable`, **or**
/// - title (case-insensitive) is in the skip list.
public func isNonMeeting(_ event: CandidateEvent, skipList: [String] = defaultSkipList) -> Bool {
    if event.isAllDay { return true }
    if event.availability == .free || event.availability == .unavailable { return true }
    let lower = event.title.lowercased()
    return skipList.contains { lower == $0.lowercased() }
}

/// Filter a collection of candidates, returning only meeting events.
public func meetingCandidates(
    from events: [CandidateEvent],
    skipList: [String] = defaultSkipList
) -> [CandidateEvent] {
    events.filter { !isNonMeeting($0, skipList: skipList) }
}

// MARK: - Resolution

/// The outcome of calendar lookup at session start (plan.md ADR-13).
public enum EventResolution: Sendable {
    /// No meeting events overlap the current time → use a timestamped default name.
    case none
    /// Exactly one meeting event matched → use its title silently.
    case single(EventSnapshot)
    /// Multiple events matched → show a picker (Phase 3) or use `--event-id` in CLI.
    case multiple([EventSnapshot])
}

/// Resolve an array of filtered candidates into an `EventResolution`.
public func resolveEvents(_ candidates: [CandidateEvent]) -> EventResolution {
    switch candidates.count {
    case 0: return .none
    case 1: return .single(snapshot(from: candidates[0]))
    default: return .multiple(candidates.map(snapshot(from:)))
    }
}

/// Return an event title when there's a single match, or the default title for `date` otherwise.
public func resolveTitle(from resolution: EventResolution, at date: Date) -> String {
    switch resolution {
    case .single(let snap): return snap.title
    case .none, .multiple: return Session.defaultTitle(for: date)
    }
}

/// Map a `CandidateEvent` to an `EventSnapshot` for persistence into `session.json`.
public func snapshot(from candidate: CandidateEvent) -> EventSnapshot {
    EventSnapshot(
        eventIdentifier: candidate.identifier,
        title: candidate.title,
        attendees: candidate.attendees,
        notes: candidate.notes,
        startDate: candidate.startDate,
        endDate: candidate.endDate,
        calendarTitle: candidate.calendarTitle
    )
}

// MARK: - CalendarService

/// Read-only EventKit integration for ADR-13. Queries events overlapping a point in time,
/// applies the non-meeting filter, and returns an `EventResolution`.
///
/// Calendar permission is optional — if denied, the service silently degrades to `.none`.
@available(macOS 14, *)
public final class CalendarService: Sendable {
    // EKEventStore is a class type and non-Sendable; it's created inside async methods
    // rather than stored as a property, keeping this type Sendable.

    /// User-editable skip list, injected so Settings can override the defaults (plan.md M3.6).
    public let skipList: [String]

    public init(skipList: [String] = defaultSkipList) {
        self.skipList = skipList
    }

    // MARK: - Permission

    /// Request full read access to the user's calendars.
    /// Returns `true` if access was granted (or was already granted).
    public func requestAccess() async -> Bool {
        let store = EKEventStore()
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    // MARK: - Query

    /// Fetch meeting candidates overlapping `date` from the default event store.
    ///
    /// Returns `.none` immediately if calendar access has not been granted, rather
    /// than triggering an unexpected TCC prompt (caller should call `requestAccess` first
    /// during onboarding).
    public func currentCandidates(at date: Date = Date()) async -> EventResolution {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return .none
        }
        let store = EKEventStore()
        let window: TimeInterval = 60 * 60 // Search 1 h before and after `date`.
        let start = date.addingTimeInterval(-window)
        let end = date.addingTimeInterval(window)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let ekEvents = store.events(matching: predicate)

        let candidates = ekEvents
            .filter { $0.startDate <= date && $0.endDate >= date }
            .map { makeCandidateEvent(from: $0) }

        let filtered = meetingCandidates(from: candidates, skipList: skipList)
        return resolveEvents(filtered)
    }

    // MARK: - EKEvent → CandidateEvent

    private func makeCandidateEvent(from event: EKEvent) -> CandidateEvent {
        let attendees: [Attendee] = (event.attendees ?? []).compactMap { participant in
            let name = participant.name ?? participant.url.absoluteString
            // EKParticipant.url is a mailto: URL; extract the email if present.
            let email: String? = {
                let raw = participant.url.absoluteString
                return raw.hasPrefix("mailto:") ? String(raw.dropFirst("mailto:".count)) : nil
            }()
            return Attendee(name: name, email: email)
        }

        return CandidateEvent(
            identifier: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "",
            isAllDay: event.isAllDay,
            availability: event.availability,
            startDate: event.startDate,
            endDate: event.endDate,
            attendees: attendees,
            notes: event.notes,
            calendarTitle: event.calendar?.title
        )
    }
}
