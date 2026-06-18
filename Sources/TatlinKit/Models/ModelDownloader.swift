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

    /// Stream-download `url` into `destination`, calling `onProgress` with each chunk.
    ///
    /// `URLSession` is intentionally scoped to this call (not stored on the actor) because
    /// `URLSession` is non-Sendable and would violate strict concurrency if stored.
    private func downloadFile(
        from url: URL,
        to destination: URL,
        spec: ModelSpec,
        file: ModelFile,
        onProgress: @Sendable @escaping (DownloadProgress) -> Void
    ) async throws {
        let (localTmp, response): (URL, URLResponse)
        do {
            (localTmp, response) = try await URLSession.shared.download(from: url)
        } catch {
            throw DownloadError.networkError(underlying: error)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: localTmp)
            throw DownloadError.httpError(statusCode: http.statusCode, url: url)
        }

        // Move URLSession temp file to our staging path.
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: localTmp, to: destination)
        } catch {
            throw DownloadError.filesystemError(underlying: error)
        }

        // Emit final progress.
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        let progress = DownloadProgress(
            spec: spec,
            file: file,
            bytesReceived: size,
            bytesExpected: file.sizeBytes ?? size
        )
        onProgress(progress)
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
