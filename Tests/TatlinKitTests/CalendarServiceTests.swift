import EventKit
import Foundation
import Testing
@testable import TatlinKit

// MARK: - isNonMeeting tests

@Suite("CalendarService — non-meeting filter")
struct NonMeetingFilterTests {

    private func makeEvent(
        title: String = "Standup",
        isAllDay: Bool = false,
        availability: EKEventAvailability = .busy,
        start: Date = Date(),
        end: Date = Date().addingTimeInterval(3600)
    ) -> CandidateEvent {
        CandidateEvent(
            identifier: UUID().uuidString,
            title: title,
            isAllDay: isAllDay,
            availability: availability,
            startDate: start,
            endDate: end
        )
    }

    @Test("all-day event is excluded")
    func allDayExcluded() {
        let event = makeEvent(isAllDay: true)
        #expect(isNonMeeting(event) == true)
    }

    @Test("free availability is excluded")
    func freeExcluded() {
        let event = makeEvent(availability: .free)
        #expect(isNonMeeting(event) == true)
    }

    @Test("unavailable availability is excluded")
    func unavailableExcluded() {
        let event = makeEvent(availability: .unavailable)
        #expect(isNonMeeting(event) == true)
    }

    @Test("busy availability is included")
    func busyIncluded() {
        let event = makeEvent(title: "Standup", availability: .busy)
        #expect(isNonMeeting(event) == false)
    }

    @Test("tentative availability is included")
    func tentativeIncluded() {
        let event = makeEvent(title: "Review", availability: .tentative)
        #expect(isNonMeeting(event) == false)
    }

    @Test("Out of Office is in default skip-list")
    func outOfOfficeSkipped() {
        let event = makeEvent(title: "Out of Office")
        #expect(isNonMeeting(event) == true)
    }

    @Test("OOO is in default skip-list")
    func oooSkipped() {
        let event = makeEvent(title: "OOO")
        #expect(isNonMeeting(event) == true)
    }

    @Test("Focus Time is in default skip-list")
    func focusTimeSkipped() {
        let event = makeEvent(title: "Focus Time")
        #expect(isNonMeeting(event) == true)
    }

    @Test("Focus is in default skip-list")
    func focusSkipped() {
        let event = makeEvent(title: "Focus")
        #expect(isNonMeeting(event) == true)
    }

    @Test("Busy title is in default skip-list")
    func busyTitleSkipped() {
        let event = makeEvent(title: "Busy")
        #expect(isNonMeeting(event) == true)
    }

    @Test("skip-list comparison is case-insensitive")
    func caseInsensitive() {
        let event = makeEvent(title: "out of office")
        #expect(isNonMeeting(event) == true)
    }

    @Test("a normal meeting title is not skipped")
    func normalMeetingIncluded() {
        let event = makeEvent(title: "Sprint Planning")
        #expect(isNonMeeting(event) == false)
    }

    @Test("custom skip-list overrides defaults")
    func customSkipList() {
        let event = makeEvent(title: "Lunch")
        // Default: Lunch is not in the skip-list.
        #expect(isNonMeeting(event, skipList: defaultSkipList) == false)
        // Custom: Lunch is skipped.
        #expect(isNonMeeting(event, skipList: ["Lunch"]) == true)
    }

    @Test("meetingCandidates filters non-meeting events")
    func meetingCandidatesFilter() {
        let events: [CandidateEvent] = [
            makeEvent(title: "Standup", availability: .busy),
            makeEvent(title: "OOO", availability: .busy),
            makeEvent(title: "Sprint Review", isAllDay: false, availability: .busy),
            makeEvent(title: "Focus Time"),
            makeEvent(isAllDay: true),
        ]
        let filtered = meetingCandidates(from: events)
        #expect(filtered.count == 2)
        #expect(filtered.allSatisfy { $0.title == "Standup" || $0.title == "Sprint Review" })
    }
}

// MARK: - resolveEvents tests

@Suite("CalendarService — event resolution")
struct EventResolutionTests {
    private func makeEvent(title: String = "Meeting") -> CandidateEvent {
        CandidateEvent(
            identifier: UUID().uuidString,
            title: title,
            isAllDay: false,
            availability: .busy,
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600)
        )
    }

    @Test("0 candidates → .none")
    func zeroIsNone() {
        let result = resolveEvents([])
        if case .none = result { } else { Issue.record("Expected .none, got \(result)") }
    }

    @Test("1 candidate → .single")
    func oneIsSingle() {
        let result = resolveEvents([makeEvent(title: "Daily Sync")])
        if case .single(let snap) = result {
            #expect(snap.title == "Daily Sync")
        } else {
            Issue.record("Expected .single, got \(result)")
        }
    }

    @Test("2 candidates → .multiple")
    func twoIsMultiple() {
        let result = resolveEvents([makeEvent(title: "A"), makeEvent(title: "B")])
        if case .multiple(let snaps) = result {
            #expect(snaps.count == 2)
        } else {
            Issue.record("Expected .multiple, got \(result)")
        }
    }

    @Test("3 candidates → .multiple with all entries")
    func threeIsMultiple() {
        let result = resolveEvents([makeEvent(), makeEvent(), makeEvent()])
        if case .multiple(let snaps) = result {
            #expect(snaps.count == 3)
        } else {
            Issue.record("Expected .multiple, got \(result)")
        }
    }

    @Test("resolveTitle returns event title for .single")
    func resolveTitleSingle() {
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let event = makeEvent(title: "Architecture Review")
        let resolution = resolveEvents([event])
        let title = resolveTitle(from: resolution, at: date)
        #expect(title == "Architecture Review")
    }

    @Test("resolveTitle returns default title for .none")
    func resolveTitleNone() {
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let resolution = resolveEvents([])
        let title = resolveTitle(from: resolution, at: date)
        #expect(title.hasPrefix("Tatlin "))
    }

    @Test("resolveTitle returns default title for .multiple")
    func resolveTitleMultiple() {
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let resolution = resolveEvents([makeEvent(), makeEvent()])
        let title = resolveTitle(from: resolution, at: date)
        #expect(title.hasPrefix("Tatlin "))
    }

    @Test("snapshot preserves all fields")
    func snapshotMapping() {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let end = start.addingTimeInterval(3600)
        let attendee = Attendee(name: "Alice", email: "alice@example.com")
        let event = CandidateEvent(
            identifier: "abc123",
            title: "Design Review",
            isAllDay: false,
            availability: .busy,
            startDate: start,
            endDate: end,
            attendees: [attendee],
            notes: "Q3 scope",
            calendarTitle: "Work"
        )
        let snap = snapshot(from: event)
        #expect(snap.eventIdentifier == "abc123")
        #expect(snap.title == "Design Review")
        #expect(snap.attendees.count == 1)
        #expect(snap.attendees[0].name == "Alice")
        #expect(snap.attendees[0].email == "alice@example.com")
        #expect(snap.notes == "Q3 scope")
        #expect(snap.startDate == start)
        #expect(snap.endDate == end)
        #expect(snap.calendarTitle == "Work")
    }
}
