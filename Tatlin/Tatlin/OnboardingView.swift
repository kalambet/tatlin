import SwiftUI
import TatlinKit

/// First-run wizard (M3.2). Walks the user through the three TCC prompts (Mic → Screen +
/// System Audio → Calendar) and a minimal model download nudge (Parakeet first), then sets
/// `@AppStorage("onboardingComplete")` so the window doesn't show again.
///
/// Calendar denial is non-blocking — the user can skip and the app falls back to
/// timestamped session names.
struct OnboardingView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(ModelCatalog.self) private var catalog
    @State private var controller = OnboardingController()
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 520, height: 460)
        .onAppear {
            focusWindow()
            controller.refreshAll()
        }
    }

    /// Re-raise the wizard after each permission prompt hands focus back to the prompting
    /// process (most noticeably after the Calendar prompt — it looked like the app had
    /// closed). Targets the window by title because Settings may also be open (re-run flow).
    private func focusWindow() {
        WindowFocus.bringToFront(titled: onboardingWindowTitle)
    }

    // MARK: - Header

    private var header: some View {
        let step = controller.step.rawValue + 1
        let total = OnboardingController.Step.allCases.count
        return HStack(spacing: 10) {
            Label("Welcome to Tatlin", systemImage: "waveform")
                .font(.title3.bold())
            Spacer()
            Text("\(step) of \(total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            ProgressView(value: Double(step), total: Double(total))
                .frame(width: 70)
                .accessibilityLabel("Step \(step) of \(total)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch controller.step {
        case .welcome:          welcomeStep
        case .microphone:       micStep
        case .screenRecording:  screenStep
        case .calendar:         calendarStep
        case .models:           modelStep
        case .done:             doneStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tatlin records the audio of your meetings on-device and turns it into searchable notes — no clouds, no servers, nothing leaves your Mac.")
                .fixedSize(horizontal: false, vertical: true)
            Text("In the next steps we'll grant a few system permissions and download the on-device models. You can change all of this later from Settings.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            bullet("Microphone — to capture your voice")
            bullet("Screen & System Audio Recording — to capture remote participants")
            bullet("Calendars (optional) — to title each meeting from your calendar")
            bullet("Models (~35 GB total) — ASR + LLM weights")
            Spacer()
        }
        .padding(20)
    }

    @ViewBuilder private func bullet(_ text: String) -> some View {
        Label(text, systemImage: "circle.fill")
            .symbolRenderingMode(.hierarchical)
            .imageScale(.small)
            .font(.callout)
    }

    private var micStep: some View {
        permissionPane(
            title: "Microphone",
            description: "Tatlin uses your microphone to capture your half of the meeting so summarization knows what you said.",
            status: controller.microphoneStatus,
            grantTitle: "Grant access",
            grant: { Task { await controller.requestMicrophone(); focusWindow() } },
            openSettings: controller.openMicrophoneSettings
        )
    }

    private var screenStep: some View {
        permissionPane(
            title: "Screen & System Audio Recording",
            description: "Required to capture the audio of remote participants on Zoom/Meet/Teams etc. Tatlin doesn't watch or record your screen — it only taps the system audio output.",
            status: controller.screenRecordingStatus,
            grantTitle: "Grant access",
            grant: { controller.requestScreenRecording(); focusWindow() },
            openSettings: controller.openScreenRecordingSettings,
            footnote: "macOS often requires you to relaunch Tatlin after granting this permission before the new state is recognized."
        )
    }

    private var calendarStep: some View {
        permissionPane(
            title: "Calendar (optional)",
            description: "Lets Tatlin title each session from the meeting on your calendar and prefill attendees as known speakers. Read-only — nothing is written or modified.",
            status: controller.calendarStatus,
            grantTitle: "Grant access",
            grant: { Task { await controller.requestCalendar(); focusWindow() } },
            openSettings: controller.openCalendarSettings,
            footnote: "Skipping this is fine — sessions get a timestamped default name."
        )
    }

    @ViewBuilder private var modelStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("On-device models")
                .font(.title3.bold())
            Text("Tatlin uses Parakeet (ASR, ~2.5 GB) and Qwen3 (summarizer, ~32 GB). You can start with just Parakeet — the menubar app will block recording until both are installed, but you can download Qwen3 later from Settings → Models without losing progress.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(catalog.rows) { row in
                if !row.spec.files.isEmpty {
                    HStack {
                        Text(row.spec.key).font(.callout.monospaced())
                        Spacer()
                        statusLabel(row.state)
                        actionButton(row)
                    }
                    .padding(.vertical, 2)
                }
            }
            Spacer()
            Text("You can also skip this step and download everything later from Settings → Models.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    @ViewBuilder private func statusLabel(_ state: ModelCatalog.Row.State) -> some View {
        switch state {
        case .installed:    Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .available:    Label("Not downloaded", systemImage: "arrow.down.circle").foregroundStyle(.secondary).font(.caption)
        case .downloading:  Text("Downloading…").font(.caption).foregroundStyle(.secondary)
        case .failed(let m):Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption).lineLimit(1)
        case .autoManaged:  Label("Auto-managed", systemImage: "wand.and.stars").foregroundStyle(.secondary).font(.caption)
        }
    }

    @ViewBuilder private func actionButton(_ row: ModelCatalog.Row) -> some View {
        switch row.state {
        case .available, .failed:
            Button("Download") { catalog.download(row.id) }
                .buttonStyle(.bordered)
        case .downloading, .installed, .autoManaged:
            EmptyView()
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("You're all set", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3.bold())
            Text("Click the Tatlin menubar icon when you're ready to record a meeting. Settings (vault folder, audio source, models) are under the gear icon in the menubar.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Text("You can re-run this guide any time from Settings → General.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    // MARK: - Permission pane helper

    @ViewBuilder private func permissionPane(
        title: String,
        description: String,
        status: OnboardingController.PermissionStatus,
        grantTitle: String,
        grant: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        footnote: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.bold())
            Text(description)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            statusRow(status)
            HStack {
                if case .granted = status {
                    EmptyView()
                } else {
                    Button(grantTitle, action: grant)
                        .buttonStyle(.borderedProminent)
                    if case .denied = status {
                        Button("Open Settings…", action: openSettings)
                            .buttonStyle(.bordered)
                    }
                }
            }
            if let footnote {
                Text(footnote).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    @ViewBuilder private func statusRow(_ status: OnboardingController.PermissionStatus) -> some View {
        switch status {
        case .unknown:
            Label("Not yet requested", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .granted:
            Label("Access granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .denied:
            Label("Access denied", systemImage: "xmark.circle.fill")
                .foregroundStyle(.orange)
        case .partial(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Back") { controller.back() }
                .disabled(controller.step == .welcome)
            Spacer()
            if controller.step == .done {
                Button("Finish") {
                    onboardingComplete = true
                    dismissWindow(id: "onboarding")
                }
                .keyboardShortcut(.defaultAction)
            } else {
                if controller.step == .calendar || controller.step == .models {
                    Button("Skip") { controller.next() }
                }
                Button("Next") { controller.next() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
