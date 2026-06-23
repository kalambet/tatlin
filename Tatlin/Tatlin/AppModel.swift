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

    enum Status: Equatable {
        case idle
        case recording
        case processing(String)
        case completed(URL)
        case failed(String)
    }

    var status: Status = .idle
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

    var isRecording: Bool { if case .recording = status { return true }; return false }
    var isBusy: Bool { if case .processing = status { return true }; return false }

    /// Menu bar glyph for the current state (M3.7). Idle and recording use the custom
    /// Tatlin Tower template images from the asset catalog (auto-tinted by macOS for
    /// light/dark menu bars); processing keeps the SF Symbol hourglass.
    var menuBarIcon: MenuBarIcon {
        switch status {
        case .recording:  return .asset("MenuBarTowerRecording")
        case .processing: return .symbol("hourglass")
        default:          return .asset("MenuBarTower")
        }
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

    func resume(_ sessionID: String) {
        guard !isRecording, !isBusy else { return }
        Task {
            status = .processing("Resuming…")
            do {
                try await runPipeline(sessionID)
            } catch {
                status = .failed(error.localizedDescription)
            }
            refreshResumable()
        }
    }

    // MARK: - Intent

    func toggle() {
        switch status {
        case .idle, .completed, .failed: start()
        case .recording:                 stop()
        case .processing:                break   // ignore while busy
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

                let recorder = SCStreamRecorder()
                try await recorder.start(session: session, store: store)
                self.recorder = recorder
                status = .recording
                preventSleepWhileRecording()

                // Stage the picker only after capture is live — keeps the recorder hot
                // even while the user is mulling over which calendar event this is.
                if !pickerCandidates.isEmpty {
                    pendingPickerSessionID = id
                    pendingPickerCandidates = pickerCandidates
                    pendingPickerToken = UUID()
                }
            } catch let error as CaptureError {
                status = .failed(Self.message(for: error))
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func stop() {
        Task {
            allowSleep()  // recording is ending — let the system idle-sleep normally again
            do {
                try await recorder?.stop()
                recorder = nil
                status = .processing("Starting…")
                if let id = currentID { try await runPipeline(id) }
            } catch {
                status = .failed(error.localizedDescription)
            }
            refreshResumable()
        }
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

    private func runPipeline(_ id: String) async throws {
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

        do {
            let url = try await pipeline.run(sessionID: id) { progress in
                Task { @MainActor in
                    self.status = .processing("[\(progress.stage.rawValue)] \(progress.message)")
                }
            }
            status = .completed(url)
            lastOutput = url
            lastSessionID = id
            notifyDone(url)
        } catch {
            status = .failed(error.localizedDescription)
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
