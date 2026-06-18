import Foundation

/// Manages the on-disk layout for downloaded models (plan.md Q7, M1B.1):
///
/// ```
/// <root>/models/{asr,diarization,llm}/<key>/
///     <relativePath for each ModelFile>
/// ```
///
/// All path arithmetic is in this struct so every other component stays consistent.
/// No FileManager I/O happens at init; access is lazy and non-throwing for path helpers.
public struct ModelStore: Sendable {
    /// Root passed from `SessionStore.root` or injected in tests.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Convenience: create a `ModelStore` rooted at the same Application Support root
    /// as a `SessionStore`.
    public init(sessionStoreRoot: URL) {
        self.root = sessionStoreRoot
    }

    // MARK: - Path helpers

    /// `<root>/models`
    public var modelsDir: URL {
        root.appendingPathComponent("models", isDirectory: true)
    }

    /// `<root>/models/{asr|diarization|llm}`
    public func kindDir(for kind: ModelKind) -> URL {
        modelsDir.appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    /// `<root>/models/<kind>/<key>/`
    public func directory(for spec: ModelSpec) -> URL {
        kindDir(for: spec.kind).appendingPathComponent(spec.key, isDirectory: true)
    }

    /// Absolute URL for one file within a model's local directory.
    public func localURL(for file: ModelFile, in spec: ModelSpec) -> URL {
        directory(for: spec).appendingPathComponent(file.relativePath, isDirectory: false)
    }

    // MARK: - Presence checks

    /// True when all files for `spec` are present on disk (not necessarily verified).
    public func isPresent(_ spec: ModelSpec) -> Bool {
        spec.files.allSatisfy { file in
            FileManager.default.fileExists(
                atPath: localURL(for: file, in: spec).path
            )
        }
    }

    /// Returns which files of `spec` are missing from disk.
    public func missingFiles(in spec: ModelSpec) -> [ModelFile] {
        spec.files.filter { file in
            !FileManager.default.fileExists(
                atPath: localURL(for: file, in: spec).path
            )
        }
    }

    // MARK: - Listing

    /// All specs from `catalogue` that have every file present on disk.
    public func installed(from catalogue: [ModelSpec] = ModelManifest.default) -> [ModelSpec] {
        catalogue.filter { isPresent($0) }
    }

    /// All specs from `catalogue` that are not yet fully downloaded.
    public func available(from catalogue: [ModelSpec] = ModelManifest.default) -> [ModelSpec] {
        catalogue.filter { !isPresent($0) }
    }
}
