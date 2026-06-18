import Foundation
import Testing
@testable import TatlinKit

@Suite("SessionStore")
struct SessionStoreTests {
    private func tempStore() throws -> SessionStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tatlin-tests-\(UUID().uuidString)", isDirectory: true)
        return try SessionStore(root: dir)
    }

    @Test("create persists and reloads a session")
    func createRoundTrip() throws {
        let store = try tempStore()
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let session = Session(id: Session.makeID(for: date), createdAt: date, title: "Standup")
        _ = try store.create(session)

        let loaded = try store.load(id: session.id)
        #expect(loaded.id == session.id)
        #expect(loaded.title == "Standup")
        #expect(loaded.completedStages.isEmpty)
    }

    @Test("markCompleted advances stage status")
    func markCompleted() throws {
        let store = try tempStore()
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let session = Session(id: Session.makeID(for: date), createdAt: date, title: "Sync")
        _ = try store.create(session)

        try store.markCompleted(.capture, for: session.id)
        #expect(try store.load(id: session.id).completedStages.contains(.capture))
    }

    @Test("resumable = captured but not finished")
    func resumable() throws {
        let store = try tempStore()
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let session = Session(id: Session.makeID(for: date), createdAt: date, title: "Review")
        _ = try store.create(session)
        try store.markCompleted(.capture, for: session.id)
        #expect(try store.resumable().count == 1)

        try store.markCompleted(.output, for: session.id)
        #expect(try store.resumable().isEmpty)
    }

    @Test("default title and id formatting")
    func formatting() {
        let date = Date(timeIntervalSince1970: 1_780_000_000) // 2026-05-28T...Z
        #expect(Session.defaultTitle(for: date).hasPrefix("Tatlin "))
        #expect(Session.makeID(for: date).contains("T"))
        #expect(Session.makeID(for: date).hasSuffix("Z"))
    }
}
