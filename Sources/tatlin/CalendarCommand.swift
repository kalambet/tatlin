import ArgumentParser
import Foundation
import TatlinKit

/// `tatlin calendar` — print the current event resolution for manual verification.
///
/// Useful for confirming that CalendarService filters correctly before a real recording.
/// Not registered in `TatlinCLI.subcommands` yet — that wiring happens during
/// Phase 1 integration (per the constraint on Tatlin.swift).
struct CalendarPeek: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calendar",
        abstract: "Show the current calendar event resolution (none / single / multiple)."
    )

    @Option(name: .long, help: "Comma-separated titles to add to the skip list (e.g. 'Lunch,Personal').")
    var skipTitles: String?

    mutating func run() async throws {
        guard #available(macOS 14, *) else {
            print("Calendar service requires macOS 14 or later.")
            return
        }

        var skipList = defaultSkipList
        if let extra = skipTitles {
            skipList += extra.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        let service = CalendarService(skipList: skipList)
        let granted = await service.requestAccess()
        guard granted else {
            print("Calendar access denied. Grant access in System Settings → Privacy → Calendars.")
            return
        }

        let now = Date()
        let resolution = await service.currentCandidates(at: now)

        switch resolution {
        case .none:
            print("Resolution: none")
            print("Title would be: \(Session.defaultTitle(for: now))")

        case .single(let snap):
            print("Resolution: single")
            print("Title: \(snap.title)")
            print("Event ID: \(snap.eventIdentifier ?? "(none)")")
            if let start = snap.startDate, let end = snap.endDate {
                print("Time: \(start) – \(end)")
            }
            if !snap.attendees.isEmpty {
                print("Attendees (\(snap.attendees.count)):")
                for a in snap.attendees {
                    let email = a.email.map { " <\($0)>" } ?? ""
                    print("  \(a.name)\(email)")
                }
            }

        case .multiple(let snaps):
            print("Resolution: multiple (\(snaps.count) candidates)")
            for snap in snaps {
                let range: String = {
                    guard let s = snap.startDate, let e = snap.endDate else { return "" }
                    return " [\(s)–\(e)]"
                }()
                print("  \(snap.title)\(range) — \(snap.attendees.count) attendees")
                print("    id: \(snap.eventIdentifier ?? "(none)")")
            }
            print("Pass --event-id <identifier> to tatlin record to select one.")
        }
    }
}
