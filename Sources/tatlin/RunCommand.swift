import ArgumentParser
import Foundation
import TatlinKit
import TatlinML

/// `tatlin run <session-id> [--from-stage <stage>]` — drive Stages 2–7 over a saved session
/// (plan.md M2.8, ADR-10). Uses the **real MLX/FluidAudio engines** by default (requires
/// downloaded model weights — see `tatlin models download`); pass `--stub` for an offline,
/// dependency-free dry run with canned output.
struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the batch pipeline (transcribe → summarize → notes) over a saved session."
    )

    @Argument(help: "Session id (directory name under sessions/, e.g. 2026-06-18T143000Z).")
    var sessionID: String

    @Option(name: .long, help: "Resume from this stage; earlier artifacts are read from disk.")
    var fromStage: PipelineStage = .transcription

    @Option(name: .long, help: "Destination vault directory for the final .md (default: the session dir).")
    var vault: String?

    @Flag(name: .long, help: "Use deterministic stub engines (no model weights needed) for an offline dry run.")
    var stub = false

    func run() async throws {
        let store = try SessionStore()
        let engines = stub
            ? EngineFactory.makeStub()
            : EngineFactory.makeReal(modelStore: ModelStore(sessionStoreRoot: store.root))
        var config = BatchPipeline.Config()
        if let vault { config.vaultDirectory = URL(fileURLWithPath: vault, isDirectory: true) }

        let pipeline = BatchPipeline(
            store: store,
            asr: engines.asr,
            diarizer: engines.diarizer,
            llm: engines.llm,
            host: ModelHost(),
            config: config
        )

        let outURL = try await pipeline.run(sessionID: sessionID, fromStage: fromStage) { p in
            print("[\(p.stage.rawValue)] \(p.message)")
        }
        print("Done → \(outURL.path)")
    }
}

// MARK: - ArgumentParser conformance for PipelineStage

extension PipelineStage: ExpressibleByArgument {}

// MARK: - Engine factory

/// Builds the engine trio the pipeline runs on.
enum EngineFactory {
    struct Engines {
        var asr: any ASREngine
        var diarizer: any DiarizerEngine
        var llm: any LLMEngine
    }

    /// Deterministic, dependency-free engines for offline dry runs and tests.
    static func makeStub() -> Engines {
        Engines(asr: StubASREngine(), diarizer: StubDiarizer(), llm: StubLLMEngine())
    }

    /// The real MLX/FluidAudio engines (Parakeet ASR, FluidAudio diarizer, Qwen summarizer),
    /// resolved against the model directories under `modelStore`. Requires downloaded weights.
    static func makeReal(modelStore: ModelStore) -> Engines {
        let trio = MLEngineFactory.make(store: modelStore, asrBackend: .parakeet)
        return Engines(asr: trio.asr, diarizer: trio.diarizer, llm: trio.llm)
    }
}
