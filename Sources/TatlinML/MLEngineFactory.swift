// MLEngineFactory.swift — TatlinML
//
// Real engine factory that wires up the concrete ML backends.
// Mirrors the stub `EngineFactory.make()` call-site in Sources/tatlin/RunCommand.swift
// so the CLI can swap stubs → real engines by changing one import + one call.
//
// To activate: see Sources/TatlinML/README.md for the exact Package.swift edits and
// the two-line change needed in RunCommand.swift.

import Foundation
import MLX
import TatlinKit

/// A resolved set of engine directories, produced by `ModelStore` after download + verification.
public struct EngineDirectories: Sendable {
    /// Root of the `parakeet-tdt-0.6b-v3` model directory.
    public let parakeet: URL
    /// Root of the `voxtral-mini-4b-realtime-2602` model directory (optional, bake-off only).
    public let voxtral: URL?
    /// Root of the WhisperKit compiled CoreML model directory.
    public let whisperKit: URL?
    /// Root of the `speaker-diarization-community-1` model directory (or nil → use FluidAudio default).
    public let diarizer: URL?
    /// Root of the `qwen3-30b-a3b-instruct-2507-mlx-8bit` model directory.
    public let qwen: URL

    public init(
        parakeet: URL,
        voxtral: URL? = nil,
        whisperKit: URL? = nil,
        diarizer: URL? = nil,
        qwen: URL
    ) {
        self.parakeet = parakeet
        self.voxtral = voxtral
        self.whisperKit = whisperKit
        self.diarizer = diarizer
        self.qwen = qwen
    }
}

/// Which ASR engine to use as the primary transcription backend.
public enum ASRBackend: Sendable {
    /// Parakeet-TDT-0.6B-v3 (primary, word timestamps supported).
    case parakeet
    /// Voxtral-Mini-4B-Realtime-2602 (bake-off; NO word timestamps — see VoxtralEngine.swift).
    case voxtral
    /// WhisperKit large-v3 (fallback, word timestamps supported).
    case whisperKit
}

/// Factory that builds the real ML engine triple used by `BatchPipeline`.
///
/// Engines returned here are **unloaded** (weights not yet in memory); call
/// `ModelHost.withASR`, `ModelHost.withDiarizer`, `ModelHost.withLLM` to load/unload
/// in strict sequential order (plan.md ADR-11).
///
/// ### Usage (in RunCommand.swift after enabling TatlinML)
/// ```swift
/// // Replace: let (asr, diarizer, llm) = EngineFactory.make()
/// // With:
/// let dirs = EngineDirectories(
///     parakeet: modelStore.directory(for: "parakeet-tdt-0.6b-v3"),
///     diarizer: modelStore.directory(for: "speaker-diarization-community-1"),
///     qwen:     modelStore.directory(for: "qwen3-30b-a3b-instruct-2507-mlx-8bit")
/// )
/// let (asr, diarizer, llm) = MLEngineFactory.make(directories: dirs)
/// ```
/// Failures raised when wiring the real engines.
public enum MLEngineFactoryError: Error, Sendable, CustomStringConvertible {
    /// A mandatory model key was absent from the catalogue — misconfigured manifest or the
    /// model isn't downloaded/registered.
    case missingModel(key: String)

    public var description: String {
        switch self {
        case .missingModel(let key): "Required model '\(key)' is missing from the catalogue."
        }
    }
}

@available(macOS 15, *)
public enum MLEngineFactory {

    /// Build a concrete `(ASREngine, DiarizerEngine, LLMEngine)` triple.
    ///
    /// - Parameters:
    ///   - directories: Pre-resolved model directory paths (from `ModelStore`).
    ///   - asrBackend: Which ASR engine to use.  Defaults to `.parakeet`.
    /// - Returns: A tuple of protocol-typed engines, ready to be handed to `ModelHost`.
    public static func make(
        directories: EngineDirectories,
        asrBackend: ASRBackend = .parakeet
    ) -> (asr: any ASREngine, diarizer: any DiarizerEngine, llm: any LLMEngine) {
        configureGPUMemory()

        let asr: any ASREngine = switch asrBackend {
        case .parakeet:
            ParakeetEngine(modelDirectory: directories.parakeet)
        case .voxtral:
            // Voxtral has no word timestamps — only use for bake-off WER scoring, not alignment.
            // See VoxtralEngine.swift module comment.
            VoxtralEngine(modelDirectory: directories.voxtral ?? directories.parakeet)
        case .whisperKit:
            WhisperKitEngine(modelDirectory: directories.whisperKit ?? directories.parakeet)
        }

        let diarizer: any DiarizerEngine = FluidDiarizer(modelDirectory: directories.diarizer)
        let llm: any LLMEngine = QwenSummarizer(modelDirectory: directories.qwen)

        return (asr: asr, diarizer: diarizer, llm: llm)
    }

    /// Convenience overload that reads directories from a `ModelStore` using the default manifest.
    ///
    /// - Parameter store: A configured `ModelStore` with all models verified/downloaded.
    /// - Parameter catalogue: The model catalogue to look up specs from. Defaults to `ModelManifest.default`.
    /// - Parameter asrBackend: Which ASR backend to use.
    /// - Returns: Concrete engine triple.
    ///
    /// Note: `ModelStore.directory(for:)` takes a `ModelSpec`, not a String.
    /// Source: Sources/TatlinKit/Models/ModelStore.swift
    public static func make(
        store: ModelStore,
        catalogue: [ModelSpec] = ModelManifest.default,
        asrBackend: ASRBackend = .parakeet
    ) throws -> (asr: any ASREngine, diarizer: any DiarizerEngine, llm: any LLMEngine) {
        // Resolve spec by key from the catalogue.
        func dir(key: String) -> URL? {
            catalogue.first(where: { $0.key == key }).map { store.directory(for: $0) }
        }

        // Parakeet (ASR) and Qwen (LLM) are mandatory; a missing key means a misconfigured
        // catalogue or an un-downloaded model — throw a clear error instead of crashing on `!`.
        guard let parakeetDir = dir(key: "parakeet-tdt-0.6b-v3") else {
            throw MLEngineFactoryError.missingModel(key: "parakeet-tdt-0.6b-v3")
        }
        guard let qwenDir = dir(key: "qwen3-30b-a3b-instruct-2507-mlx-8bit") else {
            throw MLEngineFactoryError.missingModel(key: "qwen3-30b-a3b-instruct-2507-mlx-8bit")
        }

        let dirs = EngineDirectories(
            parakeet:   parakeetDir,
            voxtral:    dir(key: "voxtral-mini-4b-realtime-2602"),
            whisperKit: dir(key: "whisperkit-large-v3"),
            diarizer:   dir(key: "speaker-diarization-community-1"),
            qwen:       qwenDir
        )
        return make(directories: dirs, asrBackend: asrBackend)
    }

    /// Bound the MLX Metal buffer cache (the `MLX.GPU.set(cacheLimit:)` guard from ADR-11 that
    /// backstops the 64 GB ceiling, research risk #6). Sequential residency (`ModelHost`) bounds
    /// the *active* set — weights + KV; this bounds the *cache* of freed buffers so they return
    /// to the OS between stages instead of accumulating. Idempotent; called before any load.
    ///
    /// Lives here, not in `ModelHost`, because TatlinKit deliberately never imports MLX. The
    /// per-stage `MLX.Memory.clearCache()` in each engine's `unload()` does the "drop refs
    /// between stages" half.
    public static func configureGPUMemory() {
        // research.md: set cacheLimit "modestly". 1 GiB gives generation buffer reuse while
        // keeping the resident footprint well under the ceiling; tune during on-device eval.
        MLX.GPU.set(cacheLimit: 1 << 30)
    }
}
