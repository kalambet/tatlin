import SwiftUI

/// Tatlin menubar app entry point (Phase 3 MVP). A thin SwiftUI shell over `TatlinKit` +
/// `TatlinML`: a `MenuBarExtra` to start/stop capture and a `Settings` window for the vault
/// path, audio source, output language, and owner name. All pipeline work is delegated to
/// `AppModel`, which reuses the same engines/pipeline the CLI uses.
@main
struct TatlinApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
