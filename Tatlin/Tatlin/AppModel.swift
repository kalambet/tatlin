import AppKit
import Foundation
import Observation
import TatlinKit
import TatlinML
import UserNotifications

/// How the menu bar label should render the current state: a custom asset-catalog
/// template image, or an SF Symbol. Lets `AppModel` stay the single source of truth
/// without importing SwiftUI.
enum MenuBarIcon: Equatable {
    case asset(String)
    case symbol(String)
}

/// Drives capture + the batch pipeline and exposes observable status to the menubar UI.
/// `@MainActor` so SwiftUI can read its state directly; heavy ML work runs off-main inside
/// the engine actors (`ParakeetEngine`, `FluidDiarizer`, `QwenSummarizer`) and `ModelHost`.
@MainActor
@Observable
final class AppModel {

    /// Capture state — deliberately independent of processing so a new recording can start
    /// the instant the previous one stops (its pipeline runs in the background queue below).
    enum Capture: Equatable { case idle, recording }
    private(set) var capture: Capture = .idle

    /// A session waiting for (or undergoing) the batch pipeline.
    struct PipelineJob: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
    }
    /// Background processing queue; `first` is the job currently running. Drains serially so
    /// only one pipeline is resident at a time (ADR-11 model residency / 64 GB ceiling).
    private(set) var processing: [PipelineJob] = []
    /// Live progress message for the running job.
    private(set) var processingMessage: String?
    private var processingTask: Task<Void, Never>?

    /// Terminal outcome of the most recent pipeline, for the menu's status line. Cleared when
    /// a new recording starts.
    enum LastResult: Equatable { case none, done, failed(String) }
    private(set) var lastResult: LastResult = .none

    var lastOutput: URL?
    /// ID of the most recently completed (or in-flight) session — drives the M3.5
    /// speaker-naming entry point in the menubar popover.
    var lastSessionID: String?
    /// Token bumped each time the user opens the speaker-naming window so SwiftUI
    /// `.onChange` fires even when called repeatedly.
    var speakerNamingToken: UUID?
    /// Sessions whose audio is captured but whose pipeline hasn't reached output. Re-runnable
    /// via `resume(_:)`. Refreshed on init and whenever a pipeline cycle finishes.
    var resumableSessions: [Session] = []
    /// Candidate events to surface in the EventPickerView (M3.1b). Non-empty means a picker
    /// should be shown for the currently capturing session. UUID token bumps on every show
    /// so SwiftUI `.onChange` fires even when the list shape is repeated.
    var pendingPickerCandidates: [EventSnapshot] = []
    var pendingPickerToken: UUID? = nil
    private var pendingPickerSessionID: String? = nil

    var isRecording: Bool { capture == .recording }
    var isProcessing: Bool { !processing.isEmpty }

    /// Menu bar glyph (M3.7): recording (red tower) takes priority; otherwise the hourglass
    /// while a background pipeline runs; otherwise the idle tower.
    var menuBarIcon: MenuBarIcon {
        if capture == .recording { return .asset("MenuBarTowerRecording") }
        if isProcessing { return .symbol("hourglass") }
        return .asset("MenuBarTower")
    }

    private let store: SessionStore
    private var recorder: SCStreamRecorder?
    private var currentID: String?
    /// Power-management assertion held only while recording, so the Mac doesn't idle-sleep
    /// and silently kill mic capture. nil when not recording. See `preventSleepWhileRecording()`.
    private var sleepAssertion: NSObjectProtocol?

    init() {
        // SessionStore only throws on a filesystem failure creating Application Support —
        // unrecoverable at launch, so fail fast.
        self.store = try! SessionStore()
        refreshResumable()
        Task {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        }
    }

    func refreshResumable() {
        resumableSessions = (try? store.resumable()) ?? []
    }

    // MARK: - Event picker (M3.1b)

    /// Apply the chosen calendar event to the in-flight session: update title + event metadata
    /// in session.json. Capture continues unaffected.
    func selectPickedEvent(_ snapshot: EventSnapshot) {
        guard let id = pendingPickerSessionID else { dismissPicker(); return }
        do {
            var session = try store.load(id: id)
            session.title = snapshot.title
            session.event = snapshot
            try store.write(session)
        } catch {
            // Non-fatal: session.json was already written with the default name.
            print("[Tatlin] picker: failed to update session metadata: \(error)")
        }
        dismissPicker()
    }

    /// Apply a user-typed custom name to the in-flight session.
    func selectCustomTitle(_ title: String) {
        guard let id = pendingPickerSessionID else { dismissPicker(); return }
        do {
            var session = try store.load(id: id)
            session.title = title
            session.event = nil
            try store.write(session)
        } catch {
            print("[Tatlin] picker: failed to update session title: \(error)")
        }
        dismissPicker()
    }

    /// Close the picker, leaving the default timestamped title in place.
    func dismissPicker() {
        pendingPickerCandidates = []
        pendingPickerToken = nil
        pendingPickerSessionID = nil
    }

    /// Re-run the pipeline for a captured-but-unprocessed session by queueing it behind any
    /// in-flight processing. Allowed while another session processes; not while recording.
    func resume(_ sessionID: String) {
        guard !isRecording else { return }
        let title = (try? store.load(id: sessionID).title) ?? sessionID
        enqueueProcessing(sessionID, title: title)
    }

    // MARK: - Intent

    func toggle() {
        switch capture {
        case .idle:      start()   // allowed even while a previous session is still processing
        case .recording: stop()
        }
    }

    // MARK: - Capture

    private func start() {
        Task {
            do {
                let now = Date()

                // Calendar peek (ADR-13). Silent on denial / no match. Skip-list is
                // read fresh from Settings each time so an edit takes effect on the
                // next Start without a relaunch.
                let settings = AppSettings.current()
                var title = Session.defaultTitle(for: now)
                var event: EventSnapshot?
                var pickerCandidates: [EventSnapshot] = []
                switch await CalendarService(skipList: settings.calendarSkipList).currentCandidates(at: now) {
                case .none:                 break
                case .single(let snap):     title = snap.title; event = snap
                case .multiple(let snaps):  pickerCandidates = snaps  // resolved via the picker (M3.1b)
                }

                let id = Session.makeID(for: now)
                let session = Session(id: id, createdAt: now, title: title, event: event)
                _ = try store.create(session)
                currentID = id

                let recorder = SCStreamRecorder(onUnrecoverableFailure: { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.isRecording else { return }
                        self.allowSleep()
                        self.recorder = nil
                        self.currentID = nil
                        self.capture = .idle
                        self.lastResult = .failed(Self.message(for: error))
                        self.notifyCaptureFailed()
                        self.refreshResumable()
                    }
                })
                try await recorder.start(session: session, store: store)
                self.recorder = recorder
                capture = .recording
                lastResult = .none
                preventSleepWhileRecording()

                // Stage the picker only after capture is live — keeps the recorder hot
                // even while the user is mulling over which calendar event this is.
                if !pickerCandidates.isEmpty {
                    pendingPickerSessionID = id
                    pendingPickerCandidates = pickerCandidates
                    pendingPickerToken = UUID()
                }
            } catch let error as CaptureError {
                capture = .idle
                currentID = nil
                lastResult = .failed(Self.message(for: error))
            } catch {
                capture = .idle
                currentID = nil
                lastResult = .failed(error.localizedDescription)
            }
        }
    }

    private func stop() {
        Task {
            allowSleep()  // recording is ending — let the system idle-sleep normally again
            let id = currentID
            currentID = nil
            do {
                try await recorder?.stop()
            } catch {
                print("[Tatlin] recorder.stop: \(error)")  // still hand off whatever we captured
            }
            recorder = nil
            capture = .idle                  // ready to record again immediately
            if let id {
                let title = (try? store.load(id: id).title) ?? id
                enqueueProcessing(id, title: title)
            }
        }
    }

    // MARK: - Processing queue

    /// Queue a session for the background pipeline and make sure the serial drainer is running.
    private func enqueueProcessing(_ id: String, title: String) {
        guard !processing.contains(where: { $0.id == id }) else { return }
        processing.append(PipelineJob(id: id, title: title))
        if processingTask == nil {
            processingTask = Task { [weak self] in await self?.drainProcessingQueue() }
        }
    }

    /// Run queued pipelines one at a time. Capture is unaffected — you can record while this
    /// runs — but only one pipeline is ever resident, honoring the model-residency ceiling.
    private func drainProcessingQueue() async {
        while let job = processing.first {
            processingMessage = "Starting…"
            do {
                let url = try await runPipeline(job.id)
                lastResult = .done
                lastOutput = url
                lastSessionID = job.id
                notifyDone(url)
            } catch {
                lastResult = .failed(error.localizedDescription)
            }
            processing.removeFirst()
            processingMessage = nil
            refreshResumable()
        }
        processingTask = nil
    }

    /// Hold a power assertion that keeps the *system* awake while recording, so the mic keeps
    /// capturing when the user steps away. Uses `.idleSystemSleepDisabled` (not
    /// `.idleDisplaySleepDisabled`), so the display is still free to sleep — only full system
    /// idle sleep is blocked. Idempotent; the token is released in `allowSleep()`.
    private func preventSleepWhileRecording() {
        guard sleepAssertion == nil else { return }
        sleepAssertion = ProcessInfo.processInfo.beginActivity(
            options: .idleSystemSleepDisabled,
            reason: "Tatlin is recording meeting audio"
        )
    }

    /// Release the recording sleep assertion, letting the Mac idle-sleep normally again.
    private func allowSleep() {
        guard let sleepAssertion else { return }
        ProcessInfo.processInfo.endActivity(sleepAssertion)
        self.sleepAssertion = nil
    }

    // MARK: - Pipeline

    /// Run stages 2–7 for a session and return the written notes URL. Terminal/queue state is
    /// owned by `drainProcessingQueue`; this only reports progress via `processingMessage`.
    private func runPipeline(_ id: String) async throws -> URL {
        let settings = AppSettings.current()
        print("[Tatlin] runPipeline id=\(id) audioSource=\(settings.audioSource.rawValue) vault=\(settings.vaultDirectory?.path ?? "(default)")")
        let modelStore = ModelStore(sessionStoreRoot: store.root)
        let trio = MLEngineFactory.make(store: modelStore, asrBackend: .parakeet)

        // Sandboxed write to a user-picked vault is only allowed while the security
        // scope is held. Start on entry, stop on exit; nil-fallback means we'll write
        // into the session folder instead.
        let vaultURL: URL? = {
            guard let url = settings.vaultDirectory,
                  url.startAccessingSecurityScopedResource() else { return nil }
            return url
        }()
        defer { vaultURL?.stopAccessingSecurityScopedResource() }

        let config = BatchPipeline.Config(
            outputLanguage: settings.outputLanguage,
            ownerName: settings.ownerName,
            vaultDirectory: vaultURL,
            audioSource: settings.audioSource
        )
        let pipeline = BatchPipeline(
            store: store, asr: trio.asr, diarizer: trio.diarizer, llm: trio.llm, config: config
        )

        return try await pipeline.run(sessionID: id) { progress in
            Task { @MainActor in
                self.processingMessage = "[\(progress.stage.rawValue)] \(progress.message)"
            }
        }
    }

    // MARK: - Speaker naming (M3.5)

    /// Row shown by `SpeakerNamingView` — one diarizer label that has a representative
    /// embedding the user could enroll under a real name.
    struct SpeakerNamingCandidate: Identifiable, Sendable {
        let label: String
        let sampleText: String
        let embedding: SpeakerEmbedding
        var id: String { label }
    }

    /// Bump the token so the speaker-naming window opens.
    func presentSpeakerNaming() {
        guard lastSessionID != nil else { return }
        speakerNamingToken = UUID()
    }

    /// Read `diarization.json` + `aligned.json` for `lastSessionID` and produce one
    /// candidate per diarizer label that has an embedding, with a short sample of what
    /// that voice said for visual disambiguation.
    func loadNamingCandidates() throws -> [SpeakerNamingCandidate] {
        guard let id = lastSessionID else { return [] }
        let dir = store.directory(for: id)
        let diarization = try Self.readJSON(Diarization.self, from: dir.appendingPathComponent("diarization.json"))
        let aligned = (try? Self.readJSON(AlignedTranscript.self, from: dir.appendingPathComponent("aligned.json")))
            ?? AlignedTranscript(words: [], segments: [])

        // First text we see per speaker label, capped so the row stays readable.
        var samples: [String: String] = [:]
        for seg in aligned.segments {
            guard samples[seg.speaker] == nil else { continue }
            samples[seg.speaker] = String(seg.text.prefix(140))
        }

        return diarization.embeddings
            .map { SpeakerNamingCandidate(label: $0.key, sampleText: samples[$0.key] ?? "", embedding: $0.value) }
            .sorted { $0.label < $1.label }
    }

    /// Enroll a batch of label → real-name pairs into `EnrollmentStore`. Returns the number
    /// of profiles actually saved.
    @discardableResult
    func enrollSpeakers(_ names: [String: String]) -> Int {
        let store = EnrollmentStore(root: self.store.root)
        var profiles = (try? store.load()) ?? [:]
        var written = 0
        // Need the diarization embeddings for the labels we're enrolling.
        guard let id = lastSessionID else { return 0 }
        let dir = self.store.directory(for: id)
        guard let diarization = try? Self.readJSON(Diarization.self, from: dir.appendingPathComponent("diarization.json")) else {
            return 0
        }
        for (label, name) in names {
            guard let embedding = diarization.embeddings[label] else { continue }
            profiles[name] = embedding
            written += 1
        }
        try? store.save(profiles)
        return written
    }

    private static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Helpers

    private func notifyDone(_ url: URL) {
        let content = UNMutableNotificationContent()
        content.title = "Tatlin — notes ready"
        content.body = url.lastPathComponent
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func notifyCaptureFailed() {
        let content = UNMutableNotificationContent()
        content.title = "Tatlin — recording interrupted"
        content.body = "Audio capture stopped unexpectedly. The partial recording was saved — you can resume it from the menu."
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func message(for error: CaptureError) -> String {
        switch error {
        case .screenCapturePermissionDenied:
            return "Screen & System Audio Recording permission is required. Grant it in "
                + "System Settings ▸ Privacy & Security ▸ Screen Recording, then reopen Tatlin."
        case .microphonePermissionDenied:
            return "Microphone permission is required. Grant it in "
                + "System Settings ▸ Privacy & Security ▸ Microphone."
        case .noShareableDisplay:
            return "No display available to capture."
        case .streamStartFailed(let underlying):
            return "Couldn't start capture: \(underlying.localizedDescription)"
        case .streamStalledUnrecoverable:
            return "Capture stalled and couldn't recover."
        }
    }
}

/// Snapshot of user settings translated into pipeline types. Single source of truth read by
/// `runPipeline`, mirroring the `@AppStorage` keys written by `SettingsView`.
struct AppSettings {
    var vaultDirectory: URL?
    var audioSource: BatchPipeline.AudioSource
    var outputLanguage: SummaryPrompt.OutputLanguage
    var ownerName: String
    /// Resolved skip-list: the user's custom entries when non-empty, else `defaultSkipList`.
    var calendarSkipList: [String]

    static func current() -> AppSettings {
        let defaults = UserDefaults.standard
        let source = BatchPipeline.AudioSource(rawValue: defaults.string(forKey: "audioSource") ?? "merged") ?? .merged

        let language: SummaryPrompt.OutputLanguage
        switch defaults.string(forKey: "outputLanguage") ?? "match" {
        case "english": language = .pinned("English")
        case "german":  language = .pinned("Deutsch")
        case "russian": language = .pinned("Русский")
        default:        language = .matchMeeting
        }

        let owner = defaults.string(forKey: "ownerName") ?? "You"

        // Skip-list: empty editor → defaults; otherwise newline-split + trim + drop blanks.
        let rawSkip = defaults.string(forKey: "calendarSkipList") ?? ""
        let parsed = rawSkip.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let skipList = parsed.isEmpty ? defaultSkipList : parsed

        // Sandboxed (ADR-9a): the only writable vault URL is the one resolved from the
        // stored security-scoped bookmark. A plain path string from @AppStorage is
        // display-only and can't be written to.
        return AppSettings(
            vaultDirectory: VaultBookmark.resolve(),
            audioSource: source,
            outputLanguage: language,
            ownerName: owner.isEmpty ? "You" : owner,
            calendarSkipList: skipList
        )
    }
}
