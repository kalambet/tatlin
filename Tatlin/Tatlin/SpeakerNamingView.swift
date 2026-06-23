import SwiftUI
import TatlinKit

/// Self-improving loop (M3.5): after a pipeline finishes, lets the user attach real names
/// to the anonymous diarizer labels in the just-completed session. Each name + embedding
/// is written to `EnrollmentStore` so future sessions resolve the same voice automatically
/// (SpeakerResolver layer 2).
///
/// This does NOT rewrite the current notes.md — the LLM-applied labels are already baked.
/// Future sessions benefit. A "re-run summary" button is a possible follow-up but out of
/// scope for v1.
struct SpeakerNamingView: View {
    let model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var candidates: [AppModel.SpeakerNamingCandidate] = []
    @State private var names: [String: String] = [:]
    @State private var loadError: String?
    @State private var savedNotice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Name the speakers")
                .font(.headline)
            Text("Type a real name for each voice in this meeting. Saved names will auto-apply to future meetings — the notes for this session aren't rewritten.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            } else if candidates.isEmpty {
                Label("No speaker embeddings to label in this session.", systemImage: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                List {
                    ForEach(candidates) { candidate in
                        speakerRow(candidate)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(minHeight: 280)
            }

            if let savedNotice {
                Label(savedNotice, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }

            HStack {
                Button("Close") { dismissWindow(id: "speaker-naming") }
                Spacer()
                Button("Save names") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(candidates.isEmpty || enrollableCount == 0)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear {
            WindowFocus.bringToFront()
            load()
        }
    }

    private var enrollableCount: Int {
        names.values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    @ViewBuilder private func speakerRow(_ c: AppModel.SpeakerNamingCandidate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(c.label).font(.body.monospaced())
                Spacer()
                TextField("Real name", text: Binding(
                    get: { names[c.id] ?? "" },
                    set: { names[c.id] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            }
            if !c.sampleText.isEmpty {
                Text("“\(c.sampleText)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private func load() {
        do {
            candidates = try model.loadNamingCandidates()
        } catch {
            loadError = "Couldn't load speaker data: \(error.localizedDescription)"
            candidates = []
        }
    }

    private func save() {
        let trimmed: [String: String] = names.reduce(into: [:]) { acc, pair in
            let v = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { acc[pair.key] = v }
        }
        guard !trimmed.isEmpty else { return }
        let count = model.enrollSpeakers(trimmed)
        savedNotice = "Saved \(count) name\(count == 1 ? "" : "s") to enrollment."
    }
}
