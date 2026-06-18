import ArgumentParser
import Foundation
import TatlinKit

/// `tatlin models` — list and download Tatlin models (plan.md M1B.1).
///
/// Not registered in `TatlinCLI.subcommands` yet — wired up by the parent at integration.
struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "List and download Tatlin models.",
        subcommands: [ModelsList.self, ModelsDownload.self],
        defaultSubcommand: ModelsList.self
    )
}

// MARK: - list

struct ModelsList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List models from the manifest (installed / available)."
    )

    func run() async throws {
        let store = try makeModelStore()
        let catalogue = ModelManifest.default

        func row(_ key: String, _ kind: String, _ license: String, _ status: String) -> String {
            pad(key, 45) + "  " + pad(kind, 12) + "  " + pad(license, 12) + "  " + status
        }

        print(row("Key", "Kind", "License", "Status"))
        print(String(repeating: "-", count: 85))

        for spec in catalogue {
            let status: String
            if spec.files.isEmpty {
                status = "FluidAudio-managed"   // provisioned by the diarizer itself, not Tatlin
            } else {
                status = store.isPresent(spec) ? "installed" : "available"
            }
            print(row(spec.key, spec.kind.rawValue, spec.license, status))
        }
    }

    /// Right-pad to `width` (Swift `%s` does not work with String args).
    private func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }
}

// MARK: - download

struct ModelsDownload: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Download a model by key."
    )

    @Argument(help: "Model key from the manifest (see `tatlin models list`).")
    var key: String

    func run() async throws {
        guard let spec = ModelManifest.default.first(where: { $0.key == key }) else {
            print("Unknown model key '\(key)'. Run `tatlin models list` to see available models.")
            throw ExitCode.failure
        }

        guard !spec.files.isEmpty else {
            print("\(spec.key) is managed by FluidAudio — it is downloaded and compiled "
                + "automatically the first time diarization runs (FluidDiarizer.load()). "
                + "Nothing to download here.")
            return
        }

        let store = try makeModelStore()
        if store.isPresent(spec) {
            print("\(spec.key) is already installed.")
            return
        }

        print("Downloading \(spec.displayName)...")
        let downloader = ModelDownloader(store: store)

        try await downloader.download(spec) { progress in
            let file = progress.file.relativePath
            if let fraction = progress.fractionCompleted {
                let bar = progressBar(fraction: fraction, width: 30)
                print("\r  \(file)  [\(bar)] \(Int(fraction * 100))%", terminator: "")
                fflush(stdout)
            } else {
                let mb = Double(progress.bytesReceived) / 1_000_000
                print("\r  \(file)  \(String(format: "%.1f", mb)) MB", terminator: "")
                fflush(stdout)
            }
        }

        print("\nDone. \(spec.key) installed.")
    }

    private func progressBar(fraction: Double, width: Int) -> String {
        let filled = Int(fraction * Double(width))
        let empty = width - filled
        return String(repeating: "=", count: filled) + String(repeating: " ", count: empty)
    }
}

// MARK: - Shared helper

private func makeModelStore() throws -> ModelStore {
    let store = try SessionStore()
    return ModelStore(sessionStoreRoot: store.root)
}
