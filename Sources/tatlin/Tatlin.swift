import ArgumentParser
import Foundation
import TatlinKit

@main
struct TatlinCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tatlin",
        abstract: "Local-first, on-device macOS meeting note-taker.",
        version: Tatlin.version,
        subcommands: [
            Record.self,
            CalendarPeek.self,
            Sessions.self,
            Models.self,
            Eval.self,
        ]
    )
}

/// List sessions on disk (and which are resumable). Capture/calendar/pipeline/eval
/// subcommands are added by Phase 1 / Phase 1B.
struct Sessions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sessions",
        abstract: "List recorded sessions and their pipeline status."
    )

    @Flag(name: .long, help: "Only show sessions that can be resumed (captured but not finished).")
    var resumable = false

    func run() async throws {
        let store = try SessionStore()
        let sessions = resumable ? try store.resumable() : try store.list()
        if sessions.isEmpty {
            print("No sessions found under \(store.sessionsDir.path)")
            return
        }
        for s in sessions {
            let done = PipelineStage.allCases
                .filter { s.completedStages.contains($0) }
                .map(\.rawValue)
                .joined(separator: ",")
            print("\(s.id)  \(s.title)  [\(done.isEmpty ? "—" : done)]")
        }
    }
}
