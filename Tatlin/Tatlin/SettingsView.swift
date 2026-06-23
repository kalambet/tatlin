import AppKit
import SwiftUI
import TatlinKit

private let calendarSkipListPlaceholder = """
Out of Office
OOO
Focus Time
Focus
Busy
"""

/// Settings window (M3.6): vault path, audio source, output language, owner name, models.
/// Persisted to `UserDefaults` via `@AppStorage`; read back by `AppSettings.current()`.
struct SettingsView: View {
    @AppStorage("vaultPath") private var vaultPath = ""
    @AppStorage("audioSource") private var audioSource = "merged"
    @AppStorage("outputLanguage") private var outputLanguage = "match"
    @AppStorage("spokenLanguage") private var spokenLanguage = "auto"
    @AppStorage("ownerName") private var ownerName = "You"
    @AppStorage("calendarSkipList") private var calendarSkipListRaw = ""
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    @Environment(ModelCatalog.self) private var catalog
    @Environment(\.openWindow) private var openWindow
    @State private var loginItem = LoginItem()

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            modelsTab
                .tabItem { Label("Models", systemImage: "shippingbox") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 420)
        .scenePadding()
        .onAppear {
            // LSUIElement=YES apps don't auto-activate when the Settings scene opens, so the
            // window lands behind whatever was foreground (see WindowFocus).
            WindowFocus.bringToFront()
            // User may have toggled login item state in System Settings since last view.
            loginItem.refresh()
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
                    Text("Remote meeting (mic + system, merged)").tag("merged")
                    Text("In-person (mic only)").tag("mic")
                    Text("System only (advanced)").tag("system")
                }
                .pickerStyle(.radioGroup)
                Picker("Spoken language", selection: $spokenLanguage) {
                    Text("Auto-detect").tag("auto")
                    Text("English").tag("english")
                    Text("German").tag("german")
                    Text("Russian").tag("russian")
                }
                .help("The language spoken in your meetings. A hint improves transcription "
                    + "accuracy for non-English audio; Auto-detect lets the model decide.")
                TextField("Your name", text: $ownerName)
            }

            Section {
                Toggle("Start at login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                loginItemFooter
                HStack {
                    Text("First-run guide")
                    Spacer()
                    Button("Re-run…") {
                        onboardingComplete = false
                        openWindow(id: "onboarding")
                    }
                }
            } header: {
                Text("Launch")
            }

            Section {
                TextField(
                    "Skip-list",
                    text: $calendarSkipListRaw,
                    prompt: Text(calendarSkipListPlaceholder),
                    axis: .vertical
                )
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())

                HStack {
                    Spacer()
                    Button("Reset to defaults") {
                        calendarSkipListRaw = calendarSkipListPlaceholder
                    }
                    .disabled(calendarSkipListRaw == calendarSkipListPlaceholder)
                }
            } header: {
                Text("Calendar skip-list")
            } footer: {
                Text("One title per line, case-insensitive. Matching events are treated as non-meetings and excluded from the Start picker. Leave blank to use the defaults shown as placeholder.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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

    @ViewBuilder private var loginItemFooter: some View {
        switch loginItem.state {
        case .disabled, .enabled:
            EmptyView()
        case .requiresApproval:
            HStack(spacing: 6) {
                Label("Approval required in System Settings", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Spacer()
                Button("Open Login Items…") { loginItem.openLoginItemsSettings() }
                    .buttonStyle(.link)
            }
        case .unknown(let detail):
            Text("Status: \(detail)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let error = loginItem.lastErrorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.orange)
        }
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

    /// Fraction downloaded, or nil until the total size is known — so callers can fall back
    /// to an indeterminate spinner instead of showing a misleading 0%.
    private var downloadFraction: Double? {
        guard row.totalBytes > 0 else { return nil }
        return min(1.0, Double(row.bytesReceived) / Double(row.totalBytes))
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
            if let downloadFraction {
                ProgressView(value: downloadFraction)
                    .frame(width: 90)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
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
            if let downloadFraction {
                Text(Int(downloadFraction * 100).description + "%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("Downloading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
