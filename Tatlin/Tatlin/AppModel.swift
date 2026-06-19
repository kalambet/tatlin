import AppKit
import Foundation
import Observation
import TatlinKit
import TatlinML
import UserNotifications

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

    var isRecording: Bool { if case .recording = status { return true }; return false }
    var isBusy: Bool { if case .processing = status { return true }; return false }

    /// SF Symbol for the menubar icon, reflecting current state.
    var menuBarSymbol: String {
        switch status {
        case .recording:  return "record.circle.fill"
        case .processing: return "hourglass"
        default:          return "waveform"
        }
    }

    private let store: SessionStore
    private var recorder: SCStreamRecorder?
    private var currentID: String?

    init() {
        // SessionStore only throws on a filesystem failure creating Application Support —
        // unrecoverable at launch, so fail fast.
        self.store = try! SessionStore()
        Task {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
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

                // Calendar peek (ADR-13). Silent on denial / no match.
                var title = Session.defaultTitle(for: now)
                var event: EventSnapshot?
                switch await CalendarService().currentCandidates(at: now) {
                case .none:                 break
                case .single(let snap):     title = snap.title; event = snap
                case .multiple(let snaps):  if let first = snaps.first { title = first.title; event = first }
                }

                let id = Session.makeID(for: now)
                let session = Session(id: id, createdAt: now, title: title, event: event)
                _ = try store.create(session)
                currentID = id

                let recorder = SCStreamRecorder()
                try await recorder.start(session: session, store: store)
                self.recorder = recorder
                status = .recording
            } catch let error as CaptureError {
                status = .failed(Self.message(for: error))
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func stop() {
        Task {
            do {
                try await recorder?.stop()
                recorder = nil
                status = .processing("Starting…")
                if let id = currentID { try await runPipeline(id) }
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Pipeline

    private func runPipeline(_ id: String) async throws {
        let settings = AppSettings.current()
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
            notifyDone(url)
        } catch {
            status = .failed(error.localizedDescription)
        }
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

    static func current() -> AppSettings {
        let defaults = UserDefaults.standard
        let source = BatchPipeline.AudioSource(rawValue: defaults.string(forKey: "audioSource") ?? "system") ?? .system

        let language: SummaryPrompt.OutputLanguage
        switch defaults.string(forKey: "outputLanguage") ?? "match" {
        case "english": language = .pinned("English")
        case "german":  language = .pinned("Deutsch")
        case "russian": language = .pinned("Русский")
        default:        language = .matchMeeting
        }

        let owner = defaults.string(forKey: "ownerName") ?? "You"
        // Sandboxed (ADR-9a): the only writable vault URL is the one resolved from the
        // stored security-scoped bookmark. A plain path string from @AppStorage is
        // display-only and can't be written to.
        return AppSettings(
            vaultDirectory: VaultBookmark.resolve(),
            audioSource: source,
            outputLanguage: language,
            ownerName: owner.isEmpty ? "You" : owner
        )
    }
}
