import ArgumentParser
import Foundation
import TatlinKit

/// `tatlin record` — start a dual-channel capture session.
///
/// Peeks at the calendar for the current event, creates a session directory,
/// starts `SCStreamRecorder`, records until the user presses Return, then
/// stops and marks the capture stage complete.
///
/// Not registered in `TatlinCLI.subcommands` yet — that wiring happens during
/// Phase 1 integration (per the constraint on Tatlin.swift).
@available(macOS 15, *)
struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Start a dual-channel audio capture session (system + mic)."
    )

    @Option(name: .long, help: "Force a specific calendar event identifier (for ≥2 candidate events).")
    var eventID: String?

    @Option(name: .long, help: "Microphone capture device ID (nil = system default).")
    var micDeviceID: String?

    @Flag(name: .long, help: "Skip calendar lookup and use a timestamped default title.")
    var noCalendar = false

    mutating func run() async throws {
        let now = Date()
        let store = try SessionStore()

        // --- Calendar peek (ADR-13) ---
        var eventSnapshot: EventSnapshot?
        var title = Session.defaultTitle(for: now)

        if !noCalendar {
            let calendar = CalendarService()
            let resolution = await calendar.currentCandidates(at: now)

            switch resolution {
            case .none:
                print("No current meeting found; using default title.")
            case .single(let snap):
                title = snap.title
                eventSnapshot = snap
                print("Meeting: \"\(title)\"")
            case .multiple(let snaps):
                // CLI path: use --event-id if provided, else first candidate.
                if let forcedID = eventID, let match = snaps.first(where: { $0.eventIdentifier == forcedID }) {
                    title = match.title
                    eventSnapshot = match
                    print("Meeting (forced): \"\(title)\"")
                } else {
                    print("Multiple meetings found:")
                    for (i, snap) in snaps.enumerated() {
                        let attendeeCount = snap.attendees.count
                        print("  [\(i)] \(snap.title) (\(attendeeCount) attendees)")
                    }
                    print("Using first candidate; pass --event-id to select another.")
                    if let first = snaps.first {
                        title = first.title
                        eventSnapshot = first
                    }
                }
            }
        }

        // --- Create session ---
        let id = Session.makeID(for: now)
        let session = Session(
            id: id,
            createdAt: now,
            title: title,
            event: eventSnapshot
        )
        let dir = try store.create(session)
        print("Session: \(id)")
        print("Directory: \(dir.path)")

        // --- Start recorder ---
        let recorder = SCStreamRecorder(microphoneDeviceID: micDeviceID)
        try await recorder.start(session: session, store: store)
        print("Recording... press Return to stop.")
        _ = readLine()

        // --- Stop ---
        try await recorder.stop()
        print("Capture complete.")
    }
}
