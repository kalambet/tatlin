import Foundation

/// Stage 7 (M2.7, ADR-7): compose the final Obsidian `.md` — YAML front-matter, the
/// structured notes sections, then the full diarized transcript (`[Speaker]: text` per
/// `AttributedSegment`, overlap-flagged). Filename derives from the event title (sanitized)
/// else a timestamped default.
public enum MarkdownComposer {

    /// Inputs for a render. The transcript is the *resolved* (named) aligned transcript.
    public struct Document: Sendable {
        public var title: String
        public var date: Date
        public var event: EventSnapshot?
        public var notes: MeetingNotes
        public var transcript: AlignedTranscript
        public init(title: String, date: Date, event: EventSnapshot?, notes: MeetingNotes, transcript: AlignedTranscript) {
            self.title = title
            self.date = date
            self.event = event
            self.notes = notes
            self.transcript = transcript
        }
    }

    // MARK: - Render

    public static func render(_ doc: Document) -> String {
        var out = frontMatter(doc)
        out += "\n"
        out += "# \(doc.title)\n\n"
        out += notesBody(doc.notes)
        out += "\n## Transcript\n\n"
        out += transcriptBody(doc.transcript)
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    // MARK: - Front matter

    static func frontMatter(_ doc: Document) -> String {
        var lines = ["---"]
        lines.append("title: \(yamlScalar(doc.title))")
        lines.append("date: \(iso8601(doc.date))")

        let attendees = doc.event?.attendees ?? []
        if attendees.isEmpty {
            lines.append("attendees: []")
        } else {
            lines.append("attendees:")
            for a in attendees { lines.append("  - \(yamlScalar(a.name))") }
        }
        if let start = doc.event?.startDate { lines.append("event_start: \(iso8601(start))") }
        if let end = doc.event?.endDate { lines.append("event_end: \(iso8601(end))") }
        if let lang = doc.notes.language { lines.append("language: \(yamlScalar(lang))") }
        lines.append("source: Tatlin")
        lines.append("---")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Notes body

    static func notesBody(_ notes: MeetingNotes) -> String {
        var out = ""
        out += section("TL;DR", bullets: notes.tldr.isEmpty ? [] : notes.tldr.split(separator: "\n").map(String.init))
        out += section("Key Decisions", bullets: notes.decisions)
        out += "## Action Items\n\n"
        if notes.actionItems.isEmpty {
            out += "_None_\n\n"
        } else {
            for item in notes.actionItems {
                out += "- [ ] \(item.task) — **owner:** \(item.owner ?? "unassigned")\n"
            }
            out += "\n"
        }
        out += section("Open Questions", bullets: notes.openQuestions)

        out += "## Per-Speaker Highlights\n\n"
        if notes.perSpeakerHighlights.isEmpty {
            out += "_None_\n\n"
        } else {
            for speaker in notes.perSpeakerHighlights.keys.sorted() {
                out += "### \(speaker)\n\n"
                let items = notes.perSpeakerHighlights[speaker] ?? []
                if items.isEmpty { out += "_None_\n\n" }
                else { out += items.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
            }
        }
        return out
    }

    static func section(_ header: String, bullets: [String]) -> String {
        var out = "## \(header)\n\n"
        if bullets.isEmpty { out += "_None_\n\n" }
        else { out += bullets.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        return out
    }

    // MARK: - Transcript body

    static func transcriptBody(_ transcript: AlignedTranscript) -> String {
        guard !transcript.segments.isEmpty else { return "_No transcript._\n" }
        return transcript.segments.map { seg in
            let tag = seg.overlap ? "\(seg.speaker) [overlap]" : seg.speaker
            return "**\(tag):** \(seg.text)"
        }.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Filenames

    /// Sanitized output filename: `<event-title>.md` else a timestamped default.
    public static func filename(title: String?, date: Date) -> String {
        if let title, !sanitize(title).isEmpty {
            return "\(sanitize(title)).md"
        }
        return "\(Session.makeID(for: date)).md"
    }

    /// Replace path-hostile characters; collapse whitespace; trim. Returns "" if nothing left.
    static func sanitize(_ raw: String) -> String {
        let forbidden = Set("/\\:*?\"<>|")
        let replaced = String(raw.map { forbidden.contains($0) ? " " : $0 })
        return replaced.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Formatting helpers

    static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// Quote a YAML scalar when it contains characters that would break a bare scalar.
    static func yamlScalar(_ s: String) -> String {
        let needsQuote = s.contains(where: { ":#[]{}&*!|>'\"%@`".contains($0) }) || s.hasPrefix(" ") || s.hasSuffix(" ")
        if needsQuote {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return s
    }
}
