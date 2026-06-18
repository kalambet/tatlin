import ArgumentParser
import Foundation
import TatlinKit

/// `tatlin eval` — run eval metrics from the CLI (plan.md M1B.3, Part D).
///
/// Not registered in `TatlinCLI.subcommands` yet — wired up by the parent at integration.
struct Eval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eval",
        abstract: "Compute ASR/diarization eval metrics.",
        subcommands: [EvalWER.self],
        defaultSubcommand: EvalWER.self
    )
}

// MARK: - wer

struct EvalWER: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wer",
        abstract: "Compute Word Error Rate between a reference and hypothesis transcript."
    )

    @Option(name: .long, help: "Path to the reference transcript file (plain text).")
    var reference: String

    @Option(name: .long, help: "Path to the hypothesis transcript file (plain text).")
    var hypothesis: String

    @Option(name: .long, help: "Engine / model identifier tag shown in the report.")
    var engineID: String = "unknown"

    @Option(name: .long, help: "Clip identifier shown in the report.")
    var clipID: String = "clip"

    func run() async throws {
        let refURL = URL(fileURLWithPath: reference)
        let hypURL = URL(fileURLWithPath: hypothesis)

        let refText = try String(contentsOf: refURL, encoding: .utf8)
        let hypText = try String(contentsOf: hypURL, encoding: .utf8)

        let result = WER.compute(reference: refText, hypothesis: hypText)
        let evalResult = WEREvalResult(engineID: engineID, clipID: clipID, result: result)
        let report = EvalReport.werMarkdown(results: [evalResult])
        print(report)
    }
}
