import Foundation
import Testing
@testable import TatlinKit

@Suite("MarkdownComposer")
struct MarkdownComposerTests {

    private func sampleDoc() -> MarkdownComposer.Document {
        let notes = MeetingNotes(
            tldr: "Kicked off the project.",
            decisions: ["Ship Friday."],
            actionItems: [ActionItem(task: "Write notes", owner: "Anna"), ActionItem(task: "Schedule", owner: nil)],
            openQuestions: [],
            perSpeakerHighlights: ["Anna": ["Led the kickoff."]],
            language: "en"
        )
        let segs = [
            AttributedSegment(speaker: "You", start: 0, end: 2, text: "Hello everyone"),
            AttributedSegment(speaker: "Anna", start: 2, end: 4, text: "Hi", overlap: true),
        ]
        let transcript = AlignedTranscript(language: "en", words: [], segments: segs)
        let event = EventSnapshot(
            title: "Project Kickoff",
            attendees: [Attendee(name: "Anna"), Attendee(name: "Bob")],
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_003_600)
        )
        return MarkdownComposer.Document(
            title: "Project Kickoff",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            event: event, notes: notes, transcript: transcript
        )
    }

    @Test("front-matter carries title, attendees, event times, and source")
    func frontMatter() {
        let md = MarkdownComposer.render(sampleDoc())
        #expect(md.hasPrefix("---\n"))
        #expect(md.contains("title: Project Kickoff"))
        #expect(md.contains("attendees:"))
        #expect(md.contains("  - Anna"))
        #expect(md.contains("event_start:"))
        #expect(md.contains("event_end:"))
        #expect(md.contains("source: Tatlin"))
    }

    @Test("golden render: sections and diarized transcript present")
    func goldenRender() {
        let md = MarkdownComposer.render(sampleDoc())
        #expect(md.contains("## TL;DR"))
        #expect(md.contains("- Kicked off the project."))
        #expect(md.contains("- [ ] Write notes — **owner:** Anna"))
        #expect(md.contains("- [ ] Schedule — **owner:** unassigned"))
        #expect(md.contains("## Open Questions\n\n_None_"))
        #expect(md.contains("### Anna"))
        #expect(md.contains("## Transcript"))
        #expect(md.contains("**You:** Hello everyone"))
        #expect(md.contains("**Anna [overlap]:** Hi"))  // overlap flag rendered
    }

    @Test("filename: sanitized event title, else timestamped default")
    func filenames() {
        #expect(MarkdownComposer.filename(title: "Weekly: Sync/Standup", date: Date()) == "Weekly Sync Standup.md")
        let stamped = MarkdownComposer.filename(title: nil, date: Date(timeIntervalSince1970: 0))
        #expect(stamped.hasSuffix(".md"))
        #expect(stamped.contains("1970"))
    }
}
