import SwiftUI
import TatlinKit

/// Tatlin menubar app entry point (Phase 3 MVP). A thin SwiftUI shell over `TatlinKit` +
/// `TatlinML`: a `MenuBarExtra` to start/stop capture and a `Settings` window for the vault
/// path, audio source, output language, owner name, and on-device models. All pipeline work
/// is delegated to `AppModel`, which reuses the same engines/pipeline the CLI uses.
@main
struct TatlinApp: App {
    @State private var model = AppModel()
    @State private var catalog: ModelCatalog

    init() {
        // Catalog shares the same Application Support root as the session/model stores.
        // Under sandbox (ADR-9a) this resolves to the app's container automatically.
        let store = try! SessionStore()
        _catalog = State(initialValue: ModelCatalog(store: ModelStore(sessionStoreRoot: store.root)))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(catalog)
        }
    }
}
