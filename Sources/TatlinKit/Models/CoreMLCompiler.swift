import CoreML
import Foundation

/// Wraps `MLModel.compileModel(at:)` with a compile-cache so models are only compiled once
/// (plan.md M1B.1). The compiled `.mlmodelc` bundle lives beside the source model file.
///
/// `MLModel` is non-Sendable — never stored as a property. URLs are value types and safe.
public enum CoreMLCompiler {
    // MARK: - Errors

    public enum CompileError: Error, Sendable {
        /// The source model file does not exist.
        case sourceNotFound(URL)
        /// CoreML compilation failed.
        case compilationFailed(underlying: Error)
        /// Moving the compiled bundle to the cache path failed.
        case filesystemError(underlying: Error)
    }

    // MARK: - Public API

    /// Compile `modelURL` (a `.mlpackage` or `.mlmodel`) and cache the result next to the
    /// source as `<name>.mlmodelc`. Skips recompilation if the cache is already present
    /// and newer than the source.
    ///
    /// Returns the URL of the compiled `.mlmodelc` directory.
    ///
    /// `MLModel.compileModel(at:)` runs on an internal XPC service; calling from an actor
    /// is fine — the await hop releases the actor for the duration of compilation.
    public static func compile(modelURL: URL) async throws -> URL {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw CompileError.sourceNotFound(modelURL)
        }

        let compiledURL = cacheURL(for: modelURL)

        // Skip if cached and up to date.
        if let cachedMod = modificationDate(of: compiledURL),
           let sourceMod = modificationDate(of: modelURL),
           cachedMod >= sourceMod
        {
            return compiledURL
        }

        // Compile via CoreML system framework.
        let tmpURL: URL
        do {
            tmpURL = try await MLModel.compileModel(at: modelURL)
        } catch {
            throw CompileError.compilationFailed(underlying: error)
        }

        // Atomically replace any stale cached bundle.
        do {
            if FileManager.default.fileExists(atPath: compiledURL.path) {
                try FileManager.default.removeItem(at: compiledURL)
            }
            try FileManager.default.moveItem(at: tmpURL, to: compiledURL)
        } catch {
            throw CompileError.filesystemError(underlying: error)
        }

        return compiledURL
    }

    // MARK: - Helpers

    /// Canonical cache path: `<modelDir>/<modelName>.mlmodelc`.
    public static func cacheURL(for modelURL: URL) -> URL {
        let name = modelURL.deletingPathExtension().lastPathComponent
        return modelURL.deletingLastPathComponent()
            .appendingPathComponent("\(name).mlmodelc", isDirectory: true)
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[FileAttributeKey.modificationDate] as? Date
    }
}
