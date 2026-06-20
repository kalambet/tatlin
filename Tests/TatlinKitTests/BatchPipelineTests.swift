import AVFoundation
import Foundation
import Testing
@testable import TatlinKit

/// Thread-safe collector for the `@Sendable` progress callback.
private final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: Set<PipelineStage> = []
    func record(_ s: PipelineStage) { lock.lock(); stages.insert(s); lock.unlock() }
    func snapshot() -> Set<PipelineStage> { lock.lock(); defer { lock.unlock() }; return stages }
}

@Suite("BatchPipeline")
struct BatchPipelineTests {

    // MARK: - Fixtures

    /// Write a mono float32 WAV at `sampleRate`. `loudRange` (seconds) gets a tone; the rest
    /// is silence — used to give the mic channel owner energy only in [0,4].
    private func writeWAV(_ url: URL, sampleRate: Double, duration: Double, loudRange: ClosedRange<Double>?) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(sampleRate * duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let ch = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            if let r = loudRange, r.contains(t) {
                ch[i] = Float(0.5 * sin(2 * Double.pi * 220 * t))
            } else if loudRange == nil {
                ch[i] = Float(0.5 * sin(2 * Double.pi * 220 * t))  // fully voiced
            } else {
                ch[i] = 0
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    private func makeSession() throws -> (store: SessionStore, id: String, root: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tatlin-pipe-\(UUID().uuidString)", isDirectory: true)
        let store = try SessionStore(root: root)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let id = Session.makeID(for: date)
        let event = EventSnapshot(title: "Stub Meeting", attendees: [Attendee(name: "Anna")])
        var session = Session(id: id, createdAt: date, title: "Stub Meeting", event: event)
        session.completedStages = [.capture]
        let dir = try store.create(session)
        // System audio (full 8 s voiced) + mic audio (owner energy only in [0,4]).
        try writeWAV(dir.appendingPathComponent(session.systemAudioFile), sampleRate: 48_000, duration: 8, loudRange: nil)
        try writeWAV(dir.appendingPathComponent(session.micAudioFile), sampleRate: 48_000, duration: 8, loudRange: 0...4)
        return (store, id, root)
    }

    /// These tests were written for the original single-channel pipeline (one transcript.json,
    /// owner attribution via mic VAD). The default config switched to `.merged` (M2.9) in
    /// 2026-06-20; pin the legacy tests to `.system` so they keep validating the path they
    /// were written for. The new dual-channel surface gets its own test below.
    private func pipeline(_ store: SessionStore, audioSource: BatchPipeline.AudioSource = .system) -> BatchPipeline {
        BatchPipeline(
            store: store, asr: StubASREngine(), diarizer: StubDiarizer(), llm: StubLLMEngine(),
            config: .init(audioSource: audioSource)
        )
    }

    // MARK: - Tests

    @Test("end-to-end run produces parseable notes and marks every stage complete")
    func endToEnd() async throws {
        let (store, id, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }

        let seen = StageRecorder()
        let outURL = try await pipeline(store).run(sessionID: id) { p in seen.record(p.stage) }

        // Output file exists and is well-formed Markdown.
        let md = try String(contentsOf: outURL, encoding: .utf8)
        #expect(md.contains("## TL;DR"))
        #expect(md.contains("## Transcript"))
        #expect(md.contains("source: Tatlin"))

        // Every pipeline stage marked complete.
        let session = try store.load(id: id)
        for stage in PipelineStage.allCases where stage != .capture {
            #expect(session.completedStages.contains(stage), "stage \(stage) not completed")
        }

        // Intermediate artifacts written.
        let dir = store.directory(for: id)
        for artifact in ["transcript.json", "diarization.json", "aligned.json", "notes.md"] {
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(artifact).path))
        }
        #expect(seen.snapshot().contains(.output))
    }

    @Test("merged (M2.9) writes both channel transcripts and produces parseable notes")
    func mergedDualChannel() async throws {
        let (store, id, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }

        let outURL = try await pipeline(store, audioSource: .merged).run(sessionID: id)
        let md = try String(contentsOf: outURL, encoding: .utf8)
        #expect(md.contains("## TL;DR"))
        #expect(md.contains("## Transcript"))

        let dir = store.directory(for: id)
        // Dual-channel layout: separate transcript files, no legacy transcript.json.
        for artifact in ["transcript-system.json", "transcript-mic.json", "diarization.json", "aligned.json", "notes.md"] {
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(artifact).path),
                    "expected \(artifact) to be written under \(dir.path)")
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path),
                "legacy transcript.json should not be written in .merged mode")
    }

    @Test("owner anchor relabels the mic-aligned cluster to the owner name")
    func ownerAnchor() async throws {
        let (store, id, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }

        let outURL = try await pipeline(store).run(sessionID: id)
        let md = try String(contentsOf: outURL, encoding: .utf8)
        // Mic energy in [0,4] overlaps Speaker 1's turn → owner anchor → "You" in the transcript.
        #expect(md.contains("**You:**"))
        // LLM proposed Anna (inferred) for Speaker 2 (on roster) → applied.
        #expect(md.contains("Anna (inferred)"))
    }

    @Test("--from-stage resume reuses on-disk artifacts")
    func resume() async throws {
        let (store, id, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }

        // Full run writes all artifacts.
        _ = try await pipeline(store).run(sessionID: id)

        // Resume from alignment: should succeed reading transcript.json + diarization.json.
        let outURL = try await pipeline(store).run(sessionID: id, fromStage: .alignment)
        #expect(FileManager.default.fileExists(atPath: outURL.path))
    }
}
