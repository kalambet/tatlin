import ArgumentParser
import Foundation
import TatlinKit
import TatlinML

/// `tatlin transcribe <audio>` — run just the ASR engine on a file and print the transcript.
/// A debugging aid (isolates Stage 2) used to validate the real engines + downloaded weights
/// without the full pipeline. The engine resamples to 16 kHz mono internally.
@available(macOS 15, *)
struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe an audio file with the ASR engine (debug; needs downloaded weights)."
    )

    @Argument(help: "Path to an audio file (any format AVFoundation can read).")
    var audioPath: String

    @Option(name: .long, help: "ASR backend key from the manifest (default: parakeet-tdt-0.6b-v3).")
    var modelKey = "parakeet-tdt-0.6b-v3"

    func run() async throws {
        let store = try SessionStore()
        let modelStore = ModelStore(sessionStoreRoot: store.root)
        guard let spec = ModelManifest.default.first(where: { $0.key == modelKey }) else {
            throw ValidationError("No model '\(modelKey)' in the manifest. See `tatlin models list`.")
        }
        let dir = modelStore.directory(for: spec)

        let engine = ParakeetEngine(modelDirectory: dir)
        try await engine.load()
        let transcript = try await engine.transcribe(
            audioURL: URL(fileURLWithPath: audioPath),
            options: ASROptions()
        )

        print("language: \(transcript.language ?? "?")")
        for seg in transcript.segments {
            print(String(format: "[%6.2f–%6.2f] %@", seg.start, seg.end, seg.text))
        }
    }
}
