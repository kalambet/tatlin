import ArgumentParser
import Foundation
import TatlinKit

/// `tatlin clean` — wipe the CLI's Application Support root.
///
/// Per ADR-9a/ADR-10 the menubar app and the CLI keep *separate* `Application Support`
/// trees (the app's is inside its sandbox container). This subcommand only touches the
/// CLI's user-domain root at `~/Library/Application Support/dev.kalambet.tatlin/`; the
/// app's container is untouched.
struct Clean: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Delete CLI-side sessions and/or downloaded model weights.",
        discussion: """
        By default both sessions and models are removed after a confirmation prompt.
        Use --sessions / --models to scope; --dry-run to see what would be removed; \
        --yes to skip the confirmation.

        Only the CLI's store is affected (user-domain Application Support). The \
        menubar app's container is separate (sandbox-redirected) and is left alone.
        """
    )

    @Flag(name: .long, help: "Only remove sessions (keep model weights).")
    var sessions = false

    @Flag(name: .long, help: "Only remove model weights (keep sessions).")
    var models = false

    @Flag(name: .long, help: "Print what would be removed without deleting anything.")
    var dryRun = false

    @Flag(name: .shortAndLong, help: "Skip the confirmation prompt.")
    var yes = false

    func run() async throws {
        let store = try SessionStore()
        let modelStore = ModelStore(sessionStoreRoot: store.root)

        // Default = both. Explicit flags scope it.
        let scope: Scope
        switch (sessions, models) {
        case (false, false), (true, true):  scope = .both
        case (true, false):                  scope = .sessionsOnly
        case (false, true):                  scope = .modelsOnly
        }

        let targets = scope.directories(sessionsDir: store.sessionsDir, modelsDir: modelStore.modelsDir)

        // Report what we'd remove.
        var totalBytes: Int64 = 0
        var entries: [(URL, Int64)] = []
        for url in targets {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let size = directorySize(at: url)
            entries.append((url, size))
            totalBytes += size
        }

        if entries.isEmpty {
            print("Nothing to clean under \(store.root.path).")
            return
        }

        print("Would remove from \(store.root.path):")
        for (url, size) in entries {
            print("  \(url.lastPathComponent)/  (\(formatBytes(size)))")
        }
        print("Total: \(formatBytes(totalBytes))")

        if dryRun { return }

        if !yes {
            print("\nProceed? [y/N] ", terminator: "")
            let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard line == "y" || line == "yes" else {
                print("Aborted.")
                return
            }
        }

        for (url, _) in entries {
            do {
                try FileManager.default.removeItem(at: url)
                print("Removed \(url.lastPathComponent)/")
            } catch {
                print("Failed to remove \(url.path): \(error.localizedDescription)")
                throw ExitCode.failure
            }
        }
    }

    // MARK: - Scope

    private enum Scope {
        case both, sessionsOnly, modelsOnly

        func directories(sessionsDir: URL, modelsDir: URL) -> [URL] {
            switch self {
            case .both:         return [sessionsDir, modelsDir]
            case .sessionsOnly: return [sessionsDir]
            case .modelsOnly:   return [modelsDir]
            }
        }
    }

    // MARK: - Helpers

    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
