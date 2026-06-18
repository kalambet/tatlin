import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

// MARK: - Errors

/// Capture-phase failures surfaced to the CLI / app layer.
public enum CaptureError: Error, Sendable {
    /// Screen recording / system audio TCC permission was denied or revoked.
    case screenCapturePermissionDenied
    /// Microphone TCC permission was denied or revoked.
    case microphonePermissionDenied
    /// No shareable display content was returned by SCShareableContent.
    case noShareableDisplay
    /// The stream failed to start with an underlying error.
    case streamStartFailed(underlying: Error)
    /// The stream stalled (no buffers received for the watchdog interval) and
    /// could not be restarted.
    case streamStalledUnrecoverable
}

// MARK: - Mutable bridge state

/// Holds live writer references that `StreamBridge` writes to directly on the SCStream
/// callback thread. Isolation is provided by the lock; the actor updates `writers` only
/// between startCapture/stopCapture, when callbacks cannot be in flight.
///
/// Using a dedicated reference type (rather than the actor itself) avoids having to hop
/// CMSampleBuffer — which is not `sending` — across task boundaries.
private final class WriterState: @unchecked Sendable {
    // @unchecked Sendable: all access is lock-protected. Writers are set by the actor before
    // capture starts and cleared after stopCapture returns, so there is no concurrent
    // read+write between the actor and the bridge threads.
    private var _system: AudioFileWriter?
    private var _mic: AudioFileWriter?
    private let lock = NSLock()

    var systemWriter: AudioFileWriter? {
        get { lock.withLock { _system } }
        set { lock.withLock { _system = newValue } }
    }
    var micWriter: AudioFileWriter? {
        get { lock.withLock { _mic } }
        set { lock.withLock { _mic = newValue } }
    }
}

// MARK: - Delegate bridge

/// Bridges `SCStreamOutput` and `SCStreamDelegate` callbacks (ObjC class protocols) into
/// the `SCStreamRecorder` actor.
///
/// Audio samples are written to `WriterState` on the SCStream callback thread to avoid
/// sending non-`sending` CMSampleBuffers across task boundaries. Only timestamp ticks
/// (lightweight value types) are forwarded to the actor.
private final class StreamBridge: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // @unchecked Sendable: `recorder` and `writers` are set once at init; `recorder` is an
    // actor (safe to call from any thread); `writers` is itself @unchecked Sendable.
    private let recorder: SCStreamRecorder
    let writers: WriterState

    init(recorder: SCStreamRecorder, writers: WriterState) {
        self.recorder = recorder
        self.writers = writers
    }

    // MARK: SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        // Write on the callback thread; send only a timestamp tick to the actor.
        switch outputType {
        case .audio:
            try? writers.systemWriter?.append(sampleBuffer)
            Task { await recorder.tickSystem() }
        case .microphone:
            try? writers.micWriter?.append(sampleBuffer)
            Task { await recorder.tickMic() }
        default:
            break // Discard video frames.
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { await recorder.streamDidStop(with: error) }
    }
}

// MARK: - Recorder

/// Dual-channel SCStream recorder: system audio → `raw-system.wav`, mic → `raw-mic.wav`.
///
/// Architecture (plan.md ADR-1, M1.2, M1.5):
/// - `SCStreamConfiguration` with `capturesAudio + captureMicrophone`, 48 kHz mono, minimal 2×2 video.
/// - Two `AudioFileWriter`s with independent timestamp baselines per channel.
/// - A **watchdog** timer restarts the stream + flushes WAVs if no buffers arrive for `watchdogInterval`.
///
/// All mutable state is confined to this actor; `StreamBridge` / `WriterState` handle
/// cross-thread audio writing under a lock.
@available(macOS 15, *)
public actor SCStreamRecorder {
    // MARK: - Configuration

    /// Seconds without a buffer before the watchdog triggers a stream restart.
    public nonisolated let watchdogInterval: TimeInterval

    /// Optional explicit mic device ID (pass `nil` to use the system default).
    public nonisolated let microphoneDeviceID: String?

    // MARK: - State

    private var stream: SCStream?
    private var bridge: StreamBridge?
    private let writers = WriterState()

    private var sessionID: String?
    private var store: SessionStore?

    private var watchdogTask: Task<Void, Never>?
    private var lastSystemBufferTime: Date = .distantPast
    private var lastMicBufferTime: Date = .distantPast
    private var watchdogRestartCount = 0
    private let maxWatchdogRestarts = 3

    private var isRecording = false

    // MARK: - Init

    public init(
        watchdogInterval: TimeInterval = 10,
        microphoneDeviceID: String? = nil
    ) {
        self.watchdogInterval = watchdogInterval
        self.microphoneDeviceID = microphoneDeviceID
    }

    // MARK: - Public API

    /// Start recording into `store`'s session directory for `session`.
    ///
    /// Creates `raw-system.wav` and `raw-mic.wav` immediately so partial recordings
    /// survive a crash. Resolves the main display via `SCShareableContent`.
    public func start(session: Session, store: SessionStore) async throws {
        guard !isRecording else { return }

        self.sessionID = session.id
        self.store = store

        let systemURL = store.artifactURL(for: session.id, named: session.systemAudioFile)
        let micURL = store.artifactURL(for: session.id, named: session.micAudioFile)

        let sysWriter = AudioFileWriter(url: systemURL)
        let mWriter = AudioFileWriter(url: micURL)
        try sysWriter.open()
        try mWriter.open()
        writers.systemWriter = sysWriter
        writers.micWriter = mWriter

        let bridge = StreamBridge(recorder: self, writers: writers)
        self.bridge = bridge

        let stream = try await buildStream(delegate: bridge)

        do {
            try stream.addStreamOutput(bridge, type: .audio, sampleHandlerQueue: nil)
            try stream.addStreamOutput(bridge, type: .microphone, sampleHandlerQueue: nil)
            try await stream.startCapture()
        } catch {
            throw CaptureError.streamStartFailed(underlying: error)
        }

        self.stream = stream
        isRecording = true

        lastSystemBufferTime = Date()
        lastMicBufferTime = Date()
        startWatchdog()
    }

    /// Stop recording, flush WAVs, and mark the capture stage complete in `session.json`.
    public func stop() async throws {
        guard isRecording else { return }
        isRecording = false

        watchdogTask?.cancel()
        watchdogTask = nil

        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        bridge = nil

        // Clear writers after stopCapture returns (no more callbacks in flight).
        writers.systemWriter?.close()
        writers.micWriter?.close()
        writers.systemWriter = nil
        writers.micWriter = nil

        if let id = sessionID, let store {
            try store.markCompleted(.capture, for: id)
        }
        sessionID = nil
        store = nil
    }

    // MARK: - Internal callbacks (called from StreamBridge via Task)

    /// Record the arrival time of a system audio buffer (used by the watchdog).
    func tickSystem() { lastSystemBufferTime = Date() }

    /// Record the arrival time of a microphone buffer (used by the watchdog).
    func tickMic() { lastMicBufferTime = Date() }

    func streamDidStop(with error: Error) {
        guard isRecording else { return }
        Task { await attemptRestart(reason: "stream stopped: \(error)") }
    }

    // MARK: - Private helpers

    private func buildStream(delegate: SCStreamDelegate? = nil) async throws -> SCStream {
        // Verify TCC permissions by attempting to list shareable content.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.screenCapturePermissionDenied
        }
        guard let display = content.displays.first else {
            throw CaptureError.noShareableDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        // Audio capture (system output, e.g. Zoom/Teams/Meet).
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // Microphone capture (owner's voice) — macOS 15+.
        config.captureMicrophone = true
        if let deviceID = microphoneDeviceID {
            config.microphoneCaptureDeviceID = deviceID
        }
        config.sampleRate = 48_000
        config.channelCount = 1

        // Minimal video track is required by SCStream; we discard every frame.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps max

        return SCStream(filter: filter, configuration: config, delegate: delegate)
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(watchdogInterval))
                guard !Task.isCancelled else { break }
                await checkWatchdog()
            }
        }
    }

    private func checkWatchdog() async {
        guard isRecording else { return }
        let now = Date()
        let systemStalled = now.timeIntervalSince(lastSystemBufferTime) > watchdogInterval
        let micStalled = now.timeIntervalSince(lastMicBufferTime) > watchdogInterval
        if systemStalled || micStalled {
            await attemptRestart(reason: "stalled: system=\(systemStalled) mic=\(micStalled)")
        }
    }

    private func attemptRestart(reason: String) async {
        guard isRecording else { return }
        guard watchdogRestartCount < maxWatchdogRestarts else {
            isRecording = false
            watchdogTask?.cancel()
            return
        }
        watchdogRestartCount += 1

        // Flush current writers; reopen for append after stream restart.
        writers.systemWriter?.close()
        writers.micWriter?.close()
        try? writers.systemWriter?.open()
        try? writers.micWriter?.open()

        // Stop + restart the SCStream.
        if let old = stream {
            try? await old.stopCapture()
        }
        stream = nil

        do {
            let newStream = try await buildStream(delegate: bridge)
            if let bridge {
                try newStream.addStreamOutput(bridge, type: .audio, sampleHandlerQueue: nil)
                try newStream.addStreamOutput(bridge, type: .microphone, sampleHandlerQueue: nil)
            }
            try await newStream.startCapture()
            self.stream = newStream
            lastSystemBufferTime = Date()
            lastMicBufferTime = Date()
        } catch {
            // Restart failed; keep trying until maxWatchdogRestarts.
        }
    }
}
