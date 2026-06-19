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
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open last notes", systemImage: "doc.text")
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
        .buttonStyle(.plain)
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
