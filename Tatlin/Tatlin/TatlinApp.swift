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
                .environment(catalog)
        } label: {
            // The label itself is always mounted (the menu bar icon), so it's the right
            // place to observe model state and trigger the openWindow side effect that
            // brings up the event picker (M3.1b). The picker token bumps for every show
            // request so identical candidate lists still fire `.onChange`.
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(catalog)
        }

        Window("Pick a meeting", id: "event-picker") {
            EventPickerView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Name the speakers", id: "speaker-naming") {
            SpeakerNamingView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Welcome to Tatlin", id: "onboarding") {
            OnboardingView()
                .environment(catalog)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// The menu bar icon view, hosting the `openWindow` env so it can act on `pendingPickerToken`
/// flips without leaking SwiftUI environment into `AppModel`.
private struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    @AppStorage("onboardingComplete") private var onboardingComplete = false

    var body: some View {
        Image(systemName: model.menuBarSymbol)
            .onChange(of: model.pendingPickerToken) { _, newToken in
                if newToken != nil { openWindow(id: "event-picker") }
            }
            .onChange(of: model.speakerNamingToken) { _, newToken in
                if newToken != nil { openWindow(id: "speaker-naming") }
            }
            .task {
                // First-run: open the onboarding window. The MenuBarExtra label runs the
                // task as soon as the menu bar icon is installed, which is effectively at
                // app launch.
                if !onboardingComplete { openWindow(id: "onboarding") }
            }
    }
}
