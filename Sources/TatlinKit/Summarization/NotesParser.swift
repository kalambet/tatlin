import Foundation

/// Stage 6 output parsing (M2.6, research Q6): turn the model's `##` Markdown + trailing
/// ```json speaker_name_map block into `MeetingNotes` (+ `[SpeakerNameProposal]`).
///
/// Format is prompt-driven and therefore fallible — `validate(_:)` returns a list of
/// missing/malformed problems that drive a single repair pass (`SummaryPrompt.repair`).
public enum NotesParser {

    // MARK: - Parsing

    /// Parse a model completion. `language` is stamped onto the result for the front-matter.
    public static func parse(_ raw: String, language: String? = nil) -> MeetingNotes {
        let (markdown, json) = splitJSONBlock(raw)
        let proposals = parseProposals(json)

        var notes = MeetingNotes(language: language)
        notes.speakerNameProposals = proposals ?? []

        let bodies = sectionBodies(markdown)
        notes.tldr = (bodies["TL;DR"].map(bulletLines)?.joined(separator: "\n")) ?? ""
        notes.decisions = bodies["Key Decisions"].map(bulletLines) ?? []
        notes.actionItems = (bodies["Action Items"]?.split(separator: "\n").compactMap { parseActionItem(String($0)) }) ?? []
        notes.openQuestions = bodies["Open Questions"].map(bulletLines) ?? []
        notes.perSpeakerHighlights = bodies["Per-Speaker Highlights"].map(parsePerSpeaker) ?? [:]
        return notes
    }

    // MARK: - Validation

    /// Return a list of problems (empty = valid). Drives a one-shot repair (research Q6).
    public static func validate(_ raw: String) -> [String] {
        var problems: [String] = []
        let (markdown, json) = splitJSONBlock(raw)
        let bodies = sectionBodies(markdown)
        for header in SummaryPrompt.sections where bodies[header] == nil {
            problems.append("Missing `## \(header)` section.")
        }
        // Action items, when present, must carry the owner marker.
        if let ai = bodies["Action Items"] {
            let items = ai.split(separator: "\n").map(String.init).filter { $0.contains("- [") }
            for line in items where !line.contains("**owner:**") {
                problems.append("Action item missing `**owner:**`: \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        if json == nil {
            problems.append("Missing trailing ```json speaker_name_map block.")
        } else if parseProposals(json) == nil {
            problems.append("speaker_name_map JSON block is not parseable.")
        }
        return problems
    }

    // MARK: - JSON block

    /// Split off the LAST fenced ```json block; returns (markdownBeforeIt, jsonString?).
    static func splitJSONBlock(_ raw: String) -> (markdown: String, json: String?) {
        guard let fenceStart = raw.range(of: "```json", options: .backwards) else {
            return (raw, nil)
        }
        let afterFence = raw[fenceStart.upperBound...]
        guard let fenceEnd = afterFence.range(of: "```") else {
            return (String(raw[..<fenceStart.lowerBound]), nil)
        }
        let json = String(afterFence[..<fenceEnd.lowerBound])
        let markdown = String(raw[..<fenceStart.lowerBound])
        return (markdown, json)
    }

    /// Decode the proposals array. nil = block present but unparseable; [] = empty/valid.
    static func parseProposals(_ json: String?) -> [SpeakerNameProposal]? {
        guard let json, let data = json.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode([SpeakerNameProposal].self, from: data)
    }

    // MARK: - Markdown sections

    /// Map each `## Header` to its raw body text (everything until the next `##`).
    static func sectionBodies(_ markdown: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentHeader: String?
        var buffer: [String] = []

        func flush() {
            if let h = currentHeader {
                result[h] = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            buffer = []
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                flush()
                currentHeader = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else {
                buffer.append(line)
            }
        }
        flush()
        return result
    }

    /// `-` / `*` bullet lines from a section body, `_None_` → no items.
    static func bulletLines(_ body: String) -> [String] {
        body.split(separator: "\n").compactMap { raw -> String? in
            var t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- ") || t.hasPrefix("* ") { t = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            else { return nil }  // only bullet lines count
            return (t == "_None_" || t.isEmpty) ? nil : t
        }
    }

    /// Parse `- [ ] <task> — **owner:** <name>` into an `ActionItem` (owner optional).
    static func parseActionItem(_ line: String) -> ActionItem? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("- [") , let bracketEnd = t.range(of: "]") else { return nil }
        var rest = String(t[bracketEnd.upperBound...]).trimmingCharacters(in: .whitespaces)

        var owner: String?
        if let ownerRange = rest.range(of: "**owner:**") {
            owner = String(rest[ownerRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            // Drop the owner marker (and a trailing " — " separator) from the task text.
            rest = String(rest[..<ownerRange.lowerBound])
            rest = rest.replacingOccurrences(of: "—", with: " ").trimmingCharacters(in: .whitespaces)
        }
        if let o = owner, o.isEmpty || o.lowercased() == "unassigned" { owner = nil }
        guard !rest.isEmpty else { return nil }
        return ActionItem(task: rest, owner: owner)
    }

    /// Parse `### <Speaker>` sub-sections with bullet highlights.
    static func parsePerSpeaker(_ body: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var current: String?
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("### ") {
                current = String(t.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                if let c = current, result[c] == nil { result[c] = [] }
            } else if let c = current, (t.hasPrefix("- ") || t.hasPrefix("* ")), t.dropFirst(2).first != nil {
                let item = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if item != "_None_" { result[c, default: []].append(item) }
            }
        }
        return result
    }
}
