import Foundation
import Testing
@testable import TatlinKit

// MARK: - Fake resource

/// Tracks load/unload calls to verify ModelHost's eviction behaviour.
private actor LoadTracker {
    var loadCount = 0
    var unloadCount = 0

    func didLoad() { loadCount += 1 }
    func didUnload() { unloadCount += 1 }
    func reset() { loadCount = 0; unloadCount = 0 }
}

// MARK: - Tests

@Suite("ModelHost")
struct ModelHostTests {

    @Test("single key: body receives the correct value")
    func singleKeyBodyValue() async throws {
        let host = ModelHost()
        let result = try await host.withModel(
            key: "a",
            load: { 42 },
            unload: { _ in }
        ) { value in
            value * 2
        }
        #expect(result == 84)
    }

    @Test("model stays resident after body completes (same key = no reload)")
    func modelStaysResident() async throws {
        let tracker = LoadTracker()
        let host = ModelHost()

        // First call: loads "key-a".
        try await host.withModel(
            key: "key-a",
            load: {
                await tracker.didLoad()
                return "resource-a"
            },
            unload: { _ in await tracker.didUnload() }
        ) { _ in }

        let key = await host.residentKey
        #expect(key == "key-a")
        #expect(await tracker.loadCount == 1)
        #expect(await tracker.unloadCount == 0)  // still resident
    }

    @Test("second different key evicts the first")
    func secondKeyEvictsFirst() async throws {
        let tracker = LoadTracker()
        let host = ModelHost()

        // Load "first".
        try await host.withModel(
            key: "first",
            load: {
                await tracker.didLoad()
                return "resource-1"
            },
            unload: { _ in await tracker.didUnload() }
        ) { _ in }
        // "first" is resident; unloadCount=0.

        // Load "second" — evicts "first" then loads "second".
        try await host.withModel(
            key: "second",
            load: {
                await tracker.didLoad()
                return "resource-2"
            },
            unload: { _ in await tracker.didUnload() }
        ) { _ in }

        // 2 loads; "first" was evicted when "second" was requested (1 unload).
        #expect(await tracker.loadCount == 2)
        #expect(await tracker.unloadCount == 1)  // only "first" was unloaded
        let key = await host.residentKey
        #expect(key == "second")
    }

    @Test("explicit evict() unloads the resident model")
    func explicitEvict() async throws {
        let tracker = LoadTracker()
        let host = ModelHost()

        try await host.withModel(
            key: "x",
            load: {
                await tracker.didLoad()
                return "resource-x"
            },
            unload: { _ in await tracker.didUnload() }
        ) { _ in }

        #expect(await host.residentKey == "x")

        await host.evict()

        #expect(await host.residentKey == nil)
        #expect(await tracker.unloadCount == 1)
    }

    @Test("residentKey is nil before any load")
    func residentKeyNilInitially() async {
        let host = ModelHost()
        let key = await host.residentKey
        #expect(key == nil)
    }

    @Test("body failure evicts the model")
    func bodyFailureEvicts() async throws {
        let tracker = LoadTracker()
        let host = ModelHost()

        struct TestError: Error {}

        try? await host.withModel(
            key: "fail",
            load: {
                await tracker.didLoad()
                return "resource-fail"
            },
            unload: { _ in await tracker.didUnload() }
        ) { _ in
            throw TestError()
        }

        let key = await host.residentKey
        #expect(key == nil)
        #expect(await tracker.unloadCount == 1)
    }

    @Test("sequential different keys: each evicts the previous")
    func sequentialKeys() async throws {
        let tracker = LoadTracker()
        let host = ModelHost()

        for i in 0..<3 {
            try await host.withModel(
                key: "key-\(i)",
                load: {
                    await tracker.didLoad()
                    return "resource-\(i)"
                },
                unload: { _ in await tracker.didUnload() }
            ) { _ in }
        }

        // 3 loads; keys 0 and 1 were evicted when the next key loaded.
        // key-2 is still resident (no eviction for the last).
        #expect(await tracker.loadCount == 3)
        #expect(await tracker.unloadCount == 2)
        #expect(await host.residentKey == "key-2")
    }
}
