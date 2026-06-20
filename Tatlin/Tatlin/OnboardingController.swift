import AVFoundation
import AppKit
import CoreGraphics
import EventKit
import Foundation
import Observation

/// Drives the M3.2 first-run wizard: checks each TCC bucket, triggers the system prompts,
/// and reports a fresh status snapshot after each request. The view binds straight to this
/// — no SwiftUI logic inside.
///
/// Permissions covered (plan.md M3.2):
///   1. Microphone (`AVCaptureDevice` `.audio`) — required.
///   2. Screen & System Audio Recording (`CGRequestScreenCaptureAccess`) — required, may
///      need a relaunch after grant before the system reports it.
///   3. Calendars full-access (`EKEventStore.requestFullAccessToEvents`) — optional.
@MainActor
@Observable
final class OnboardingController {

    enum Step: Int, CaseIterable {
        case welcome
        case microphone
        case screenRecording
        case calendar
        case models
        case done
    }

    enum PermissionStatus: Equatable {
        case unknown        // not yet asked
        case granted
        case denied         // user said no; show open-in-Settings deep link
        case partial(String) // e.g. Calendar writeOnly — not enough for Tatlin; message explains
    }

    private(set) var step: Step = .welcome

    private(set) var microphoneStatus: PermissionStatus = .unknown
    private(set) var screenRecordingStatus: PermissionStatus = .unknown
    private(set) var calendarStatus: PermissionStatus = .unknown

    init() { refreshAll() }

    // MARK: - Navigation

    func next() {
        if let i = Step.allCases.firstIndex(of: step), i + 1 < Step.allCases.count {
            step = Step.allCases[i + 1]
            refreshAll()
        }
    }
    func back() {
        if let i = Step.allCases.firstIndex(of: step), i > 0 {
            step = Step.allCases[i - 1]
            refreshAll()
        }
    }
    func jumpToDone() { step = .done }

    // MARK: - Status

    func refreshAll() {
        microphoneStatus = Self.readMicrophone()
        screenRecordingStatus = Self.readScreenRecording()
        calendarStatus = Self.readCalendar()
    }

    private static func readMicrophone() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:               return .granted
        case .denied, .restricted:      return .denied
        case .notDetermined:            return .unknown
        @unknown default:               return .unknown
        }
    }

    private static func readScreenRecording() -> PermissionStatus {
        // CGPreflightScreenCaptureAccess() returns the *current* grant without prompting.
        // It can stay false until the app is relaunched after the user grants in Settings.
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    private static func readCalendar() -> PermissionStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:           return .granted
        case .writeOnly:            return .partial("Tatlin needs full read access (calendar peek is read-only).")
        case .denied, .restricted:  return .denied
        case .notDetermined:        return .unknown
        @unknown default:           return .unknown
        }
    }

    // MARK: - Requests

    func requestMicrophone() async {
        // notDetermined → triggers prompt; otherwise returns the cached value.
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refreshAll()
    }

    /// Triggers the screen-recording TCC prompt the first time, then opens the Settings
    /// pane on subsequent calls. The system returns the current authorization synchronously.
    func requestScreenRecording() {
        if CGPreflightScreenCaptureAccess() {
            screenRecordingStatus = .granted
        } else {
            _ = CGRequestScreenCaptureAccess()  // prompts on first call
            refreshAll()
            if case .denied = screenRecordingStatus {
                // On macOS 14+ the grant often requires a relaunch before the API reports
                // it. We open the pane so the user can complete the toggle.
                openScreenRecordingSettings()
            }
        }
    }

    func requestCalendar() async {
        let store = EKEventStore()
        _ = try? await store.requestFullAccessToEvents()
        refreshAll()
    }

    // MARK: - Deep links

    func openMicrophoneSettings() { openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") }
    func openScreenRecordingSettings() { openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") }
    func openCalendarSettings() { openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") }

    private func openURL(_ s: String) {
        guard let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }
}
