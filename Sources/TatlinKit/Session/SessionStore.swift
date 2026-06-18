import Foundation

/// Owns the on-disk session layout under Application Support (plan.md Q7):
///
/// ```
/// <root>/sessions/<id>/
///     session.json
///     raw-system.wav, raw-mic.wav
///     transcript.json, diarization.json, aligned.json, notes.md
/// ```
///
/// All artifact reads/writes go through here so stages stay re-runnable and crash-safe.
public struct SessionStore: Sendable {
    /// Root directory (defaults to `~/Library/Application Support/<bundleID>`).
    public let root: URL

    public init(root: URL? = nil) throws {
        if let root {
            self.root = root
        } else {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            self.root = appSupport.appendingPathComponent(Tatlin.bundleIdentifier, isDirectory: true)
        }
    }

    /// `<root>/sessions`
    public var sessionsDir: URL { root.appendingPathComponent("sessions", isDirectory: true) }

    /// Directory for a given session id.
    public func directory(for id: String) -> URL {
        sessionsDir.appendingPathComponent(id, isDirectory: true)
    }

    /// Create the session directory and persist the initial `session.json`.
    /// Call this the instant the user clicks Start, before audio flows.
    public func create(_ session: Session) throws -> URL {
        let dir = directory(for: session.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write(session)
        return dir
    }

    /// Absolute URL for a session artifact (e.g. the system/mic WAVs).
    public func artifactURL(for id: String, named filename: String) -> URL {
        directory(for: id).appendingPathComponent(filename, isDirectory: false)
    }

    // MARK: - session.json

    private func sessionJSONURL(for id: String) -> URL {
        directory(for: id).appendingPathComponent("session.json", isDirectory: false)
    }

    public func write(_ session: Session) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        try data.write(to: sessionJSONURL(for: session.id), options: .atomic)
    }

    public func load(id: String) throws -> Session {
        let data = try Data(contentsOf: sessionJSONURL(for: id))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Session.self, from: data)
    }

    /// All sessions on disk, newest first.
    public func list() throws -> [Session] {
        guard FileManager.default.fileExists(atPath: sessionsDir.path) else { return [] }
        let ids = try FileManager.default.contentsOfDirectory(atPath: sessionsDir.path)
        return ids.compactMap { try? load(id: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Mark a stage complete and persist.
    public func markCompleted(_ stage: PipelineStage, for id: String) throws {
        var session = try load(id: id)
        session.completedStages.insert(stage)
        try write(session)
    }

    /// Sessions that have captured audio but are missing later artifacts — surfaced for
    /// "Resume" (plan.md Q7). A session is resumable if capture is done but output isn't.
    public func resumable() throws -> [Session] {
        try list().filter { session in
            session.completedStages.contains(.capture) &&
            !session.completedStages.contains(.output)
        }
    }
}
