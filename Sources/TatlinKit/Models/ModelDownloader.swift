import CryptoKit
import Foundation

// MARK: - Progress + Errors

/// Per-file progress event emitted by `ModelDownloader`.
public struct DownloadProgress: Sendable {
    public let spec: ModelSpec
    public let file: ModelFile
    /// Bytes received so far for the current file.
    public let bytesReceived: Int64
    /// Total bytes expected; `nil` when the server omits Content-Length.
    public let bytesExpected: Int64?

    public var fractionCompleted: Double? {
        guard let total = bytesExpected, total > 0 else { return nil }
        return Double(bytesReceived) / Double(total)
    }
}

/// Failures raised by ``ModelDownloader``.
public enum DownloadError: Error, Sendable {
    /// The `urlString` in `ModelFile` is empty or not a valid URL.
    case invalidURL(String)
    /// The HTTP server returned a non-2xx status.
    case httpError(statusCode: Int, url: URL)
    /// SHA-256 of the downloaded file does not match the manifest.
    case checksumMismatch(file: String, expected: String, got: String)
    /// A filesystem operation (create dir, move, delete) failed.
    case filesystemError(underlying: Error)
    /// An underlying `URLSession` error (network, timeout, etc.).
    case networkError(underlying: Error)
}

// MARK: - Downloader actor

/// Downloads a `ModelSpec`'s files into `ModelStore`, verifying SHA-256 and atomically
/// moving each file into its final location (plan.md M1B.1).
///
/// Thread-safety: all mutable state is actor-isolated. `URLSession` is not stored as a
/// property (non-Sendable) — a new session is created per `download` call inside the
/// actor, used inline, and discarded.
public actor ModelDownloader {
    private let store: ModelStore

    public init(store: ModelStore) {
        self.store = store
    }

    // MARK: - Public API

    /// Download all files for `spec` and deliver progress via `onProgress`.
    ///
    /// Files already present *and* whose SHA-256 matches are skipped.
    /// Downloads go to a `.tmp` staging file; on success the file is SHA-256 verified
    /// and then atomically moved to its final path.
    public func download(
        _ spec: ModelSpec,
        onProgress: @Sendable @escaping (DownloadProgress) -> Void = { _ in }
    ) async throws {
        let dir = store.directory(for: spec)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw DownloadError.filesystemError(underlying: error)
        }

        for file in spec.files {
            let destination = store.localURL(for: file, in: spec)

            // Skip if already present and verified.
            if FileManager.default.fileExists(atPath: destination.path) {
                if let expected = file.sha256 {
                    let existing = try computeSHA256(at: destination)
                    if existing.lowercased() == expected.lowercased() { continue }
                    // Mismatch — re-download.
                } else {
                    continue  // No checksum to verify; treat as present.
                }
            }

            // Validate URL.
            guard !file.urlString.isEmpty, let url = URL(string: file.urlString) else {
                throw DownloadError.invalidURL(file.urlString)
            }

            // Parent directory for the destination file (relative path may include subdirs).
            let destDir = destination.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            } catch {
                throw DownloadError.filesystemError(underlying: error)
            }

            let tmp = destination.appendingPathExtension("tmp")
            defer { try? FileManager.default.removeItem(at: tmp) }

            try await downloadFile(
                from: url,
                to: tmp,
                spec: spec,
                file: file,
                onProgress: onProgress
            )

            // Verify checksum before moving into place.
            if let expected = file.sha256 {
                let got = try computeSHA256(at: tmp)
                guard got.lowercased() == expected.lowercased() else {
                    throw DownloadError.checksumMismatch(
                        file: file.relativePath,
                        expected: expected,
                        got: got
                    )
                }
            }

            // Atomic move: overwrite any stale file at destination.
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tmp, to: destination)
            } catch {
                throw DownloadError.filesystemError(underlying: error)
            }
        }
    }

    // MARK: - Private helpers

    /// Stream-download `url` into `destination`, calling `onProgress` as data arrives.
    ///
    /// Uses the completion-handler `downloadTask(with:completionHandler:)` API and a
    /// `DispatchSource` timer that polls `task.countOfBytesReceived` every 250 ms. We tried
    /// both the per-call and session-level delegate paths with the async
    /// `URLSession.download(...)` overloads, but `URLSessionDownloadDelegate.didWriteData`
    /// is unreliable on the async path — events only fire at file completion, leaving
    /// multi-GB downloads (Qwen3 shards) looking frozen.
    ///
    /// Bridged into async/await via `withCheckedThrowingContinuation`. `URLSession.shared`
    /// is used so we don't pay for per-call session setup/teardown.
    private func downloadFile(
        from url: URL,
        to destination: URL,
        spec: ModelSpec,
        file: ModelFile,
        onProgress: @Sendable @escaping (DownloadProgress) -> Void
    ) async throws {
        let (stagingURL, response): (URL, URLResponse) = try await withCheckedThrowingContinuation { cont in
            let poller = ProgressPoller(spec: spec, file: file, onProgress: onProgress)
            let task = URLSession.shared.downloadTask(with: url) { tmpURL, response, error in
                poller.stop()
                if let error {
                    cont.resume(throwing: DownloadError.networkError(underlying: error))
                    return
                }
                guard let tmpURL, let response else {
                    cont.resume(throwing: DownloadError.networkError(underlying: URLError(.unknown)))
                    return
                }
                // tmpURL is in /tmp and gets deleted when this closure returns; move it to a
                // staging location we control so the caller can verify + atomically move it.
                let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                do {
                    try FileManager.default.moveItem(at: tmpURL, to: staging)
                    cont.resume(returning: (staging, response))
                } catch {
                    cont.resume(throwing: DownloadError.filesystemError(underlying: error))
                }
            }
            poller.start(task: task)
            task.resume()
        }
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DownloadError.httpError(statusCode: http.statusCode, url: url)
        }

        // Move staging file into our destination tmp path (caller atomically renames).
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: stagingURL, to: destination)
        } catch {
            throw DownloadError.filesystemError(underlying: error)
        }

        // Final "we're done" progress so the row hits 100% even if the last timer tick
        // landed just before completion.
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        onProgress(DownloadProgress(
            spec: spec,
            file: file,
            bytesReceived: size,
            bytesExpected: file.sizeBytes ?? size
        ))
    }

    /// Compute the hex SHA-256 of a file at `url` using CryptoKit.
    private func computeSHA256(at url: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DownloadError.filesystemError(underlying: error)
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Progress poller

/// Reads `URLSessionDownloadTask.countOfBytesReceived` on a 250 ms `DispatchSource` timer
/// and forwards `DownloadProgress` events. Used because the delegate path
/// (`URLSessionDownloadDelegate.didWriteData`) is unreliable on the async URLSession
/// overloads — polling Foundation's `Progress`-equivalent counters is consistent.
///
/// `@unchecked Sendable` is justified: timer + task are touched only under the lock.
private final class ProgressPoller: @unchecked Sendable {
    private let spec: ModelSpec
    private let file: ModelFile
    private let onProgress: @Sendable (DownloadProgress) -> Void
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private weak var task: URLSessionDownloadTask?

    init(
        spec: ModelSpec,
        file: ModelFile,
        onProgress: @Sendable @escaping (DownloadProgress) -> Void
    ) {
        self.spec = spec
        self.file = file
        self.onProgress = onProgress
    }

    func start(task: URLSessionDownloadTask) {
        lock.lock()
        defer { lock.unlock() }
        self.task = task
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        lock.lock()
        let task = self.task
        lock.unlock()
        guard let task, task.state == .running else { return }
        let written = task.countOfBytesReceived
        let expected = task.countOfBytesExpectedToReceive
        let exp: Int64? = expected > 0 ? expected : file.sizeBytes
        onProgress(DownloadProgress(spec: spec, file: file, bytesReceived: written, bytesExpected: exp))
    }
}
