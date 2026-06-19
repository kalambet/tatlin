import AppKit
import SwiftUI

/// The panel shown from the menubar icon: status, start/stop, open-notes, settings, quit.
struct MenuContentView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tatlin").font(.headline)

            statusLine

            Divider()

            Button(action: model.toggle) {
                Label(buttonTitle, systemImage: buttonSymbol)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .disabled(model.isBusy)
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
