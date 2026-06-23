import Foundation

// MARK: - ModelHost

/// Enforces **strict sequential model residency**: at most one heavy model loaded at a
/// time (plan.md ADR-11). A model stays resident after `withModel` returns so back-to-back
/// calls for the same key reuse the loaded value. Requesting a *different* key unloads the
/// previous model before loading the new one.
///
/// `load` and `unload` closures are caller-supplied so `ModelHost` stays engine-agnostic
/// and never imports MLX, FluidAudio, or WhisperKit.
///
/// Example usage (in `BatchPipeline`):
/// ```swift
/// try await host.withModel(
///     key: "parakeet-tdt-0.6b-v3",
///     load: { try await ParakeetEngine() },
///     unload: { await $0.unload() }
/// ) { engine in
///     transcript = try await engine.transcribe(audioURL: url, options: options)
/// }
/// ```
///
/// MLX memory: the `MLX.GPU.set(cacheLimit:)` ceiling guard is configured in TatlinML
/// (`MLEngineFactory.configureGPUMemory()`) because TatlinKit never imports MLX; refs are
/// dropped between stages by each engine's `unload()` closure (calls `MLX.Memory.clearCache()`).
public actor ModelHost {
    // MARK: - Residency state

    /// Type-erased resident box. The value is stored as `Any` so `ModelHost` can hold
    /// any `R: Sendable` without becoming generic itself. `extract` casts it back to the
    /// concrete type; if the cast fails (different type for the same key) we evict and reload.
    private struct Resident {
        let key: String
        let value: any Sendable
        /// Unloads the model; called before the next key is loaded.
        let unload: @Sendable () async -> Void
    }

    private var resident: Resident?

    public init() {}

    // MARK: - Public API

    /// Load the model for `key`, run `body` with it, and leave it resident for reuse.
    ///
    /// - If `key` already matches the resident model and the stored value is the same `R`,
    ///   `load` is skipped and `body` runs immediately with the cached value.
    /// - If a *different* key is resident it is unloaded before `load` is called.
    /// - On `body` failure the model is evicted so the next caller gets a clean load.
    ///
    /// - Parameters:
    ///   - key:    Stable identifier matching `ModelSpec.key`.
    ///   - load:   Produces the loaded model resource.
    ///   - unload: Releases resources when the model is evicted. Defaults to no-op.
    ///   - body:   Work to perform with the resident model.
    public func withModel<R: Sendable, T>(
        key: String,
        load: @Sendable () async throws -> R,
        unload: @escaping @Sendable (R) async -> Void = { _ in },
        body: (R) async throws -> T
    ) async throws -> T {
        // Evict if a different key is resident.
        if let current = resident, current.key != key {
            await current.unload()  // engine unload() clears the MLX cache (drops refs)
            resident = nil
        }

        // Try to reuse the resident value if key and type both match.
        let value: R
        if let current = resident, current.key == key, let cached = current.value as? R {
            value = cached
        } else {
            // Either nothing is resident, or the key matches but R changed (shouldn't happen
            // in practice but handle defensively). Evict any stale resident first.
            if let current = resident {
                await current.unload()
                resident = nil
            }
            value = try await load()
            let capturedValue = value
            resident = Resident(key: key, value: capturedValue) {
                await unload(capturedValue)
            }
        }

        do {
            return try await body(value)
        } catch {
            // Evict on body failure so the next caller gets a clean state.
            await resident?.unload()
            resident = nil
            throw error
        }
    }

    /// Evict whatever model is currently resident (if any).
    public func evict() async {
        if let current = resident {
            await current.unload()  // engine unload() clears the MLX cache (drops refs)
            resident = nil
        }
    }

    /// The key of the currently resident model, or `nil` if none is loaded.
    public var residentKey: String? { resident?.key }
}
