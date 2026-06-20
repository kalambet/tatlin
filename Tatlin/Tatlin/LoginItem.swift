import Foundation
import Observation
import ServiceManagement

/// Wraps `SMAppService.mainApp` so SwiftUI can bind a Toggle to the "Start at login" state
/// without dealing with the AppKit/ServiceManagement APIs directly.
///
/// `SMAppService.mainApp` registers the running `.app` itself as a Login Item — no helper
/// bundle, no embedded XPC service. macOS 13+ only; this is the path ADR-8 / M3.3 calls for
/// and works with the App Sandbox (no privileged entitlement needed; Hardened Runtime is
/// already on).
///
/// User may revoke / re-enable from System Settings → General → Login Items at any time;
/// `refresh()` re-reads the live status so the Settings UI stays consistent after a manual
/// flip.
@MainActor
@Observable
final class LoginItem {

    enum State {
        case disabled
        case enabled
        /// User has to approve in System Settings → Login Items before macOS will run it.
        case requiresApproval
        /// SMAppService returned a status we don't recognize; treat as off but surface in UI.
        case unknown(String)
    }

    private(set) var state: State = .disabled
    /// Last error from `register()` / `unregister()`, if any. Cleared on the next attempt.
    private(set) var lastErrorMessage: String?

    init() { refresh() }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .notRegistered:        state = .disabled
        case .enabled:              state = .enabled
        case .requiresApproval:     state = .requiresApproval
        case .notFound:             state = .unknown("not found")
        @unknown default:           state = .unknown("status=\(SMAppService.mainApp.status.rawValue)")
        }
    }

    /// Two-way binding helper for `Toggle("Start at login", isOn: ...)`.
    var isEnabled: Bool {
        get {
            if case .enabled = state { return true }
            return false
        }
        set {
            setEnabled(newValue)
        }
    }

    func setEnabled(_ on: Bool) {
        lastErrorMessage = nil
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
        refresh()
    }

    /// Open System Settings → Login Items so the user can approve a `.requiresApproval` state
    /// or revoke the registration manually.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
