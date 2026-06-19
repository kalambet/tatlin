import AppKit
import SwiftUI

/// Settings window (M3.6): vault path, audio source, output language, owner name.
/// Persisted to `UserDefaults` via `@AppStorage`; read back by `AppSettings.current()`.
struct SettingsView: View {
    @AppStorage("vaultPath") private var vaultPath = ""
    @AppStorage("audioSource") private var audioSource = "system"
    @AppStorage("outputLanguage") private var outputLanguage = "match"
    @AppStorage("ownerName") private var ownerName = "You"

    var body: some View {
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
                            Button("Reset") { vaultPath = "" }
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
        .frame(width: 460)
        .scenePadding()
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Vault"
        if panel.runModal() == .OK, let url = panel.url {
            vaultPath = url.path
        }
    }
}
