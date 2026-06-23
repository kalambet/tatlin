import AppKit
import SwiftUI
import TatlinKit

/// Shown on Start (M3.1b / ADR-13) when `CalendarService.currentCandidates(at:)` returns
/// `.multiple`. Capture has already begun by the time this window appears — picking just
/// attaches the chosen event metadata to the in-flight session.
struct EventPickerView: View {
    let model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var customTitle: String = ""
    @State private var customSelected: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which meeting is this?")
                .font(.headline)
            Text("Recording has already started. Pick an event to tag this session, or use a custom name.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            List {
                ForEach(model.pendingPickerCandidates, id: \.eventIdentifier) { candidate in
                    Button {
                        model.selectPickedEvent(candidate)
                        dismissWindow(id: "event-picker")
                    } label: {
                        candidateRow(candidate)
                    }
                    .buttonStyle(.plain)
                }
                customRow
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 220)

            HStack {
                Button("Use default name") {
                    model.dismissPicker()
                    dismissWindow(id: "event-picker")
                }
                Spacer()
                if customSelected {
                    Button("Use this name") {
                        let trimmed = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        model.selectCustomTitle(trimmed)
                        dismissWindow(id: "event-picker")
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            WindowFocus.bringToFront()  // LSUIElement app: force the picker window forward.
        }
    }

    @ViewBuilder private func candidateRow(_ c: EventSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "calendar")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.body)
                HStack(spacing: 6) {
                    if let timeText = Self.timeRange(c.startDate, c.endDate) {
                        Text(timeText)
                    }
                    if !c.attendees.isEmpty {
                        Text("• \(c.attendees.count) attendee\(c.attendees.count == 1 ? "" : "s")")
                    }
                    if let cal = c.calendarTitle, !cal.isEmpty {
                        Text("• \(cal)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var customRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("None of these — use a custom name", isOn: $customSelected)

            if customSelected {
                TextField("Meeting name", text: $customTitle)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(.vertical, 2)
    }

    private static func timeRange(_ start: Date?, _ end: Date?) -> String? {
        guard let start, let end else { return nil }
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }
}
