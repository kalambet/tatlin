import AppKit
import SwiftUI
import TatlinKit

/// The panel shown from the menubar icon: status, start/stop, open-notes, settings, quit.
struct MenuContentView: View {
    let model: AppModel
    @Environment(ModelCatalog.self) private var catalog

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tatlin").font(.headline)

            statusLine

            if !catalog.isReady {
                missingModelsNotice
            }

            Divider()

            Button(action: model.toggle) {
                Label(buttonTitle, systemImage: buttonSymbol)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .disabled(model.isBusy || !catalog.isReady)
            .help(catalog.isReady ? "" : "Download required models from Settings → Models first.")
            .keyboardShortcut(.defaultAction)

            if let url = model.lastOutput {
                Button {
                    openInObsidian(url)
                } label: {
                    Label("Open last notes", systemImage: "doc.text")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
            }

            if model.lastSessionID != nil {
                Button {
                    model.presentSpeakerNaming()
                } label: {
                    Label("Name speakers…", systemImage: "person.crop.circle.badge.questionmark")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
            }

            if !model.resumableSessions.isEmpty {
                resumableSection
            }

            Divider()

            SettingsLink {
                Label("Settings…", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit Tatlin", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(MenuRowButtonStyle())
        .padding(12)
        .frame(width: 300)
    }

    @ViewBuilder private var resumableSection: some View {
        Divider()
        Text("Resume")
            .font(.caption)
            .foregroundStyle(.secondary)
        ForEach(model.resumableSessions.prefix(3), id: \.id) { session in
            Button {
                model.resume(session.id)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.title).lineLimit(1).truncationMode(.middle)
                        Text(Self.relativeDate(session.createdAt))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .disabled(model.isBusy || model.isRecording || !catalog.isReady)
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

    @ViewBuilder private var missingModelsNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("On-device models not installed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            SettingsLink {
                Text("Open Settings → Models")
                    .font(.caption)
                    .underline()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch model.status {
        case .idle:
            Label("Idle", systemImage: "circle").foregroundStyle(.secondary)
        case .recording:
            Label("Recording…", systemImage: "record.circle.fill").foregroundStyle(.red)
        case .processing(let message):
            Label(message, systemImage: "hourglass").foregroundStyle(.secondary).lineLimit(2)
        case .completed:
            Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).lineLimit(4)
        }
    }

    private var buttonTitle: String { model.isRecording ? "Stop" : "Start Recording" }
    private var buttonSymbol: String { model.isRecording ? "stop.fill" : "record.circle" }
}

/// Row style for the MenuBarExtra `.window` panel. Because the panel is custom SwiftUI
/// (not a native `NSMenu`), rows don't get hover highlighting for free. This mirrors the
/// macOS menu-bar extras (Wi-Fi / Battery / Control Center): a subtle translucent fill on
/// hover/press that keeps the text color, with disabled rows neither highlighting nor
/// reacting to hover.
private struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRow(configuration: configuration)
    }

    private struct MenuRow: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let active = isEnabled && (hovering || configuration.isPressed)
            configuration.label
                .opacity(isEnabled ? 1 : 0.35)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.10))
                        .opacity(active ? 1 : 0)
                }
                .onHover { hovering = isEnabled && $0 }
                .animation(.easeOut(duration: 0.08), value: active)
        }
    }
}
