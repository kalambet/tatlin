import Foundation
import Observation
import TatlinKit

/// View model behind the Settings → Models table. Wraps `ModelStore` + `ModelDownloader`
/// and exposes per-spec status the UI can render directly.
///
/// Lives on the main actor so SwiftUI can read state without hops; download work is
/// handed off to the `ModelDownloader` actor and only progress messages bounce back.
@MainActor
@Observable
final class ModelCatalog {

    /// One row per `ModelSpec` in the manifest.
    struct Row: Identifiable {
        let spec: ModelSpec
        var state: State
        /// Sum of `sizeBytes` for files already finished in the current download (resume
        /// from skipped + completed-this-session). Resets on `restart`.
        var completedBytes: Int64 = 0
        /// Bytes written to the file currently in flight (`URLSession` totalBytesWritten).
        var currentFileBytes: Int64 = 0
        /// `relativePath` of the file currently in flight, or `nil` between files.
        var currentFile: String? = nil

        var id: String { spec.key }
        var totalBytes: Int64 { spec.files.compactMap(\.sizeBytes).reduce(0, +) }
        var bytesReceived: Int64 { completedBytes + currentFileBytes }

        enum State: Equatable {
            case installed
            case available
            case downloading
            case failed(String)
            /// FluidAudio's diarizer — provisioned by the engine itself, nothing to download.
            case autoManaged
        }
    }

    private(set) var rows: [Row] = []

    private let store: ModelStore
    private let downloader: ModelDownloader

    init(store: ModelStore) {
        self.store = store
        self.downloader = ModelDownloader(store: store)
        refresh()
    }

    // MARK: - Intent

    func refresh() {
        rows = ModelManifest.default.map { spec in
            let state: Row.State
            if spec.files.isEmpty {
                state = .autoManaged
            } else if store.isPresent(spec) {
                state = .installed
            } else {
                state = .available
            }
            return Row(spec: spec, state: state)
        }
    }

    func download(_ key: String) {
        guard let index = rows.firstIndex(where: { $0.id == key }) else { return }
        let row = rows[index]
        guard row.state == .available || isFailed(row.state) else { return }

        // Pre-seed completedBytes with files already on disk: the downloader will skip them
        // (no progress events) so the bar starts at the right offset rather than 0%.
        let alreadyOnDisk = row.spec.files
            .filter { FileManager.default.fileExists(atPath: store.localURL(for: $0, in: row.spec).path) }
            .compactMap(\.sizeBytes)
            .reduce(0, +)

        rows[index].state = .downloading
        rows[index].completedBytes = alreadyOnDisk
        rows[index].currentFileBytes = 0
        rows[index].currentFile = nil

        Task { [downloader, spec = row.spec] in
            do {
                try await downloader.download(spec) { progress in
                    Task { @MainActor in
                        self.update(key: spec.key, file: progress.file.relativePath, received: progress.bytesReceived)
                    }
                }
                await MainActor.run { self.markInstalled(key: spec.key) }
            } catch {
                await MainActor.run { self.markFailed(key: spec.key, error: error) }
            }
        }
    }

    func delete(_ key: String) {
        guard let index = rows.firstIndex(where: { $0.id == key }) else { return }
        guard case .installed = rows[index].state else { return }
        let dir = store.directory(for: rows[index].spec)
        do {
            try FileManager.default.removeItem(at: dir)
            rows[index].state = .available
            rows[index].completedBytes = 0
            rows[index].currentFileBytes = 0
            rows[index].currentFile = nil
        } catch {
            rows[index].state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Private

    private func update(key: String, file: String, received: Int64) {
        guard let index = rows.firstIndex(where: { $0.id == key }) else { return }
        if rows[index].currentFile != file {
            // The previous file is done; its last-known byte count rolls into completedBytes.
            rows[index].completedBytes += rows[index].currentFileBytes
            rows[index].currentFile = file
            rows[index].currentFileBytes = 0
        }
        // Foundation reports cumulative-per-file, so overwrite (never accumulate).
        rows[index].currentFileBytes = received
    }

    private func markInstalled(key: String) {
        guard let index = rows.firstIndex(where: { $0.id == key }) else { return }
        rows[index].state = .installed
        rows[index].completedBytes = rows[index].totalBytes
        rows[index].currentFileBytes = 0
        rows[index].currentFile = nil
    }

    private func isFailed(_ state: Row.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func markFailed(key: String, error: Error) {
        guard let index = rows.firstIndex(where: { $0.id == key }) else { return }
        rows[index].state = .failed(Self.message(for: error))
    }

    private static func message(for error: Error) -> String {
        if let de = error as? DownloadError {
            switch de {
            case .invalidURL(let s):                       return "Invalid URL: \(s)"
            case .httpError(let code, _):                  return "HTTP \(code)"
            case .checksumMismatch(let file, _, _):        return "Checksum mismatch on \(file)"
            case .filesystemError(let underlying):         return "Filesystem error: \(underlying.localizedDescription)"
            case .networkError(let underlying):            return "Network error: \(underlying.localizedDescription)"
            }
        }
        return error.localizedDescription
    }
}
