import AppKit
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
        .menuBarExtraStyle(.menu)

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

        Window(onboardingWindowTitle, id: "onboarding") {
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
        menuBarImage
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

    /// Renders the state's glyph (M3.7): custom Tatlin Tower template image for
    /// idle/recording, SF Symbol for processing. Template images are auto-tinted by
    /// macOS to match the menu bar; the fixed height keeps the vector PDF menu-bar sized.
    @ViewBuilder private var menuBarImage: some View {
        switch model.menuBarIcon {
        case .asset(let name):
            Image(name).renderingMode(.template).resizable().scaledToFit().frame(height: 18)
        case .symbol(let symbol):
            Image(systemName: symbol)
        }
    }
}

/// User-visible title of the onboarding window. Shared by the `Window` scene and
/// `OnboardingView`'s window-focusing so the two can't drift apart.
let onboardingWindowTitle = "Welcome to Tatlin"

/// Brings an accessory (`LSUIElement`) app's window frontmost. Such apps don't auto-activate
/// when a SwiftUI `Window`/`Settings` scene opens, and every system permission prompt hands
/// focus back to the prompting process — so our windows sink behind other apps. A plain
/// `openWindow`/`makeKeyAndOrderFront` can't raise above *other* apps for an agent;
/// `activate(ignoringOtherApps:)` + `orderFrontRegardless()` can. Centralized here because
/// four scenes need it (Settings, onboarding, event picker, speaker naming).
@MainActor
enum WindowFocus {
    /// Raise the app's frontmost key-capable window, or the window with `title` when several
    /// are open (the onboarding wizard, which can be re-run while Settings is up).
    static func bringToFront(titled title: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let window: NSWindow? = if let title {
            NSApp.windows.first { $0.title == title }
        } else {
            NSApp.keyWindow ?? NSApp.windows.last { $0.canBecomeKey }
        }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
