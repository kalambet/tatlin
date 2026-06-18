import ArgumentParser
import Foundation
import TatlinKit

/// `tatlin run <session-id> [--from-stage <stage>]` — drive Stages 2–7 over a saved session
/// (plan.md M2.8, ADR-10). Uses the **stub engines by default** so the pipeline runs with no
/// ML dependencies; swap in the real trio via `EngineFactory` once TatlinML is enabled.
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

    func run() async throws {
        let store = try SessionStore()
        let engines = EngineFactory.make()
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

// MARK: - Engine factory (TatlinML extension point)

/// Builds the engine trio the pipeline runs on. Stub engines today; the single swap-point
/// for the real MLX/FluidAudio engines once the `TatlinML` target is enabled.
enum EngineFactory {
    struct Engines {
        var asr: any ASREngine
        var diarizer: any DiarizerEngine
        var llm: any LLMEngine
    }

    static func make() -> Engines {
        // TODO: swap in TatlinML engine factory when the ML target is enabled
        //   return Engines(asr: try ParakeetEngine(), diarizer: try FluidDiarizer(), llm: try QwenSummarizer())
        Engines(asr: StubASREngine(), diarizer: StubDiarizer(), llm: StubLLMEngine())
    }
}
