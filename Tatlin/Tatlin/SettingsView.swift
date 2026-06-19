import AppKit
import SwiftUI
import TatlinKit

/// Settings window (M3.6): vault path, audio source, output language, owner name, models.
/// Persisted to `UserDefaults` via `@AppStorage`; read back by `AppSettings.current()`.
struct SettingsView: View {
    @AppStorage("vaultPath") private var vaultPath = ""
    @AppStorage("audioSource") private var audioSource = "system"
    @AppStorage("outputLanguage") private var outputLanguage = "match"
    @AppStorage("ownerName") private var ownerName = "You"

    @Environment(ModelCatalog.self) private var catalog

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            modelsTab
                .tabItem { Label("Models", systemImage: "shippingbox") }
        }
        .frame(width: 560, height: 420)
        .scenePadding()
        .onAppear {
            // LSUIElement=YES apps don't auto-activate when the Settings scene opens, so the
            // window lands behind whatever was foreground. Force activation + front-order.
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.keyWindow ?? NSApp.windows.last(where: { $0.canBecomeKey }) {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("Output") {
                LabeledContent("Vault folder") {
                    HStack {
                        Text(vaultPath.isEmpty ? "Session folder (default)" : vaultPath)
                            .foregroundStyle(vaultPath.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…", action: chooseVault)
                        if !vaultPath.isEmpty {
                            Button("Reset") {
                                VaultBookmark.clear()
                                vaultPath = ""
                            }
                        }
                    }
                }
                Picker("Output language", selection: $outputLanguage) {
                    Text("Match meeting").tag("match")
                    Text("English").tag("english")
                    Text("German").tag("german")
                    Text("Russian").tag("russian")
                }
            }

            Section("Capture") {
                Picker("Audio source", selection: $audioSource) {
                    Text("System (remote participants)").tag("system")
                    Text("Microphone (in-person)").tag("mic")
                }
                .pickerStyle(.radioGroup)
                TextField("Your name", text: $ownerName)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Models

    private var modelsTab: some View {
        Form {
            Section {
                ForEach(catalog.rows) { row in
                    ModelRow(row: row, catalog: catalog)
                }
            } header: {
                Text("On-device models")
            } footer: {
                Text("Stored in this app's sandbox container. The CLI (`tatlin`) keeps its own copy under ~/Library/Application Support/dev.kalambet.tatlin/.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Vault"
        if panel.runModal() == .OK, let url = panel.url {
            // Bookmark first, then update display. If the bookmark fails we leave the
            // display alone — better to show "(default)" than a path we can't write to.
            do {
                try VaultBookmark.save(url)
                vaultPath = url.path
            } catch {
                NSSound.beep()
            }
        }
    }
}

// MARK: - Row

private struct ModelRow: View {
    let row: ModelCatalog.Row
    let catalog: ModelCatalog

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.spec.displayName)
                    .font(.body)
                    .lineLimit(2)
                Spacer()
                action
            }
            HStack(spacing: 8) {
                Text(row.spec.kind.rawValue.uppercased())
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Text(row.spec.license)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if row.totalBytes > 0 {
                    Text(formatBytes(row.totalBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusLabel
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var action: some View {
        switch row.state {
        case .available:
            Button("Download") { catalog.download(row.id) }
                .buttonStyle(.bordered)
        case .installed:
            Button("Delete", role: .destructive) { catalog.delete(row.id) }
                .buttonStyle(.bordered)
        case .downloading:
            ProgressView()
                .controlSize(.small)
        case .failed:
            Button("Retry") { catalog.download(row.id) }
                .buttonStyle(.bordered)
        case .autoManaged:
            EmptyView()
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch row.state {
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .available:
            Label("Not downloaded", systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .downloading:
            let fraction = row.totalBytes > 0
                ? min(1.0, Double(row.bytesReceived) / Double(row.totalBytes))
                : 0
            Text(Int(fraction * 100).description + "%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .help(message)
        case .autoManaged:
            Label("Auto-managed", systemImage: "wand.and.stars")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Downloaded and compiled by FluidAudio on first use.")
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
