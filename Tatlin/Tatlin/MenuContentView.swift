import AppKit
import SwiftUI
import TatlinKit

/// The native menu shown from the menubar icon, rendered as a real `NSMenu` via
/// `MenuBarExtra { … }.menuBarExtraStyle(.menu)` (see `TatlinApp`). Recording is a checkmark
/// `Toggle` — the same affordance AppKit uses for the connected Wi-Fi network
/// (`NSMenuItem.state == .on`); resumable sessions live in a native "Resume" submenu; and the
/// pipeline status is a disabled header item. Because nothing here is custom-drawn, the menu
/// inherits the system's metrics, highlight, keyboard navigation, and VoiceOver for free.
struct MenuContentView: View {
    let model: AppModel
    @Environment(ModelCatalog.self) private var catalog

    var body: some View {
        // Non-interactive status header — a bare Label renders as a disabled menu item.
        Label(statusText, systemImage: statusSymbol)

        if !catalog.isReady {
            Divider()
            Label("On-device models not installed", systemImage: "exclamationmark.triangle.fill")
            SettingsLink {
                Label("Open Settings → Models", systemImage: "arrow.down.circle")
            }
        }

        Divider()

        // Recording on/off as a native checkmark item: ✓ while recording, unchecked when idle.
        // The custom binding routes the click through `AppModel.toggle()` (which owns the
        // start/stop side effects) and reflects live state via `isRecording`.
        Toggle(isOn: Binding(get: { model.isRecording },
                             set: { _ in model.toggle() })) {
            Label("Recording", systemImage: "record.circle")
        }
        .disabled(model.isBusy || !catalog.isReady)
        .keyboardShortcut("r")

        if let url = model.lastOutput {
            Button {
                openInObsidian(url)
            } label: {
                Label("Open last notes", systemImage: "doc.text")
            }
        }

        if model.lastSessionID != nil {
            Button {
                model.presentSpeakerNaming()
            } label: {
                Label("Name speakers…", systemImage: "person.crop.circle.badge.questionmark")
            }
        }

        if !model.resumableSessions.isEmpty {
            Menu {
                ForEach(model.resumableSessions.prefix(5), id: \.id) { session in
                    Button {
                        model.resume(session.id)
                    } label: {
                        Text("\(session.title) — \(Self.relativeDate(session.createdAt))")
                    }
                }
            } label: {
                Label("Resume", systemImage: "arrow.clockwise")
            }
            .disabled(model.isBusy || model.isRecording || !catalog.isReady)
        }

        Divider()

        SettingsLink {
            Label("Settings…", systemImage: "gearshape")
        }
        .keyboardShortcut(",")

        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("Quit Tatlin", systemImage: "power")
        }
        .keyboardShortcut("q")
    }

    /// One-line summary of the pipeline state for the disabled header item. Multi-line/colored
    /// rendering isn't available in a native `NSMenu`, so processing/failure detail collapses
    /// to a single line (the SF Symbol carries the state cue).
    private var statusText: String {
        switch model.status {
        case .idle: "Idle"
        case .recording: "Recording…"
        case .processing(let message): message
        case .completed: "Done"
        case .failed(let message): message
        }
    }

    private var statusSymbol: String {
        switch model.status {
        case .idle: "circle"
        case .recording: "record.circle.fill"
        case .processing: "hourglass"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private static func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// Open a note in Obsidian via its URL scheme; fall back to the default app handler if
    /// Obsidian isn't installed/registered. `obsidian://open?path=<abs>` lets Obsidian
    /// resolve the containing vault on its own — no vault-name configuration needed.
    private func openInObsidian(_ url: URL) {
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: url.path)]

        if let deepLink = components.url,
           NSWorkspace.shared.urlForApplication(toOpen: deepLink) != nil {
            NSWorkspace.shared.open(deepLink)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
