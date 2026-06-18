import Foundation

// MARK: - Result types

/// WER measurement for one audio clip / engine pair.
public struct WEREvalResult: Sendable {
    public let engineID: String
    public let clipID: String
    public let result: WERResult

    public init(engineID: String, clipID: String, result: WERResult) {
        self.engineID = engineID
        self.clipID = clipID
        self.result = result
    }
}

/// DER measurement for one audio clip / engine pair.
public struct DEREvalResult: Sendable {
    public let engineID: String
    public let clipID: String
    public let result: DERResult

    public init(engineID: String, clipID: String, result: DERResult) {
        self.engineID = engineID
        self.clipID = clipID
        self.result = result
    }
}

// MARK: - Report renderer

/// Builds Markdown evaluation reports (plan.md M1B.3/4, Part D).
///
/// Returns the report as a `String`; callers decide where to write it.
/// No paths are hardcoded here.
public enum EvalReport {
    // MARK: - WER report

    /// Render a Markdown table of WER results, grouped by engine.
    ///
    /// Includes per-clip rows and a macro-average row per engine.
    public static func werMarkdown(results: [WEREvalResult], title: String = "ASR Bake-off — WER") -> String {
        var lines: [String] = ["# \(title)", ""]

        let engines = orderedUnique(results.map(\.engineID))
        for engineID in engines {
            let rows = results.filter { $0.engineID == engineID }
            lines.append("## \(engineID)")
            lines.append("")
            lines.append("| Clip | Ref Len | Sub | Ins | Del | WER |")
            lines.append("|------|--------:|----:|----:|----:|----:|")
            for row in rows.sorted(by: { $0.clipID < $1.clipID }) {
                lines.append(werRow(clipID: row.clipID, r: row.result))
            }
            // Macro average.
            let avg = averageWER(rows.map(\.result))
            lines.append("| **avg** | **\(avg.referenceLength)** | **\(avg.substitutions)** | **\(avg.insertions)** | **\(avg.deletions)** | **\(pct(avg.rate))** |")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - DER report

    /// Render a Markdown table of DER results, grouped by engine.
    public static func derMarkdown(results: [DEREvalResult], title: String = "Diarization — DER") -> String {
        var lines: [String] = ["# \(title)", ""]

        let engines = orderedUnique(results.map(\.engineID))
        for engineID in engines {
            let rows = results.filter { $0.engineID == engineID }
            lines.append("## \(engineID)")
            lines.append("")
            lines.append("| Clip | Ref Speech (s) | Missed (s) | FA (s) | Confusion (s) | DER |")
            lines.append("|------|---------------:|-----------:|-------:|--------------:|----:|")
            for row in rows.sorted(by: { $0.clipID < $1.clipID }) {
                lines.append(derRow(clipID: row.clipID, r: row.result))
            }
            let avg = averageDER(rows.map(\.result))
            lines.append("| **avg** | **\(fmt(avg.totalReferenceSpeech))** | **\(fmt(avg.missedSpeech))** | **\(fmt(avg.falseAlarm))** | **\(fmt(avg.speakerConfusion))** | **\(pct(avg.rate))** |")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func werRow(clipID: String, r: WERResult) -> String {
        "| \(clipID) | \(r.referenceLength) | \(r.substitutions) | \(r.insertions) | \(r.deletions) | \(pct(r.rate)) |"
    }

    private static func derRow(clipID: String, r: DERResult) -> String {
        "| \(clipID) | \(fmt(r.totalReferenceSpeech)) | \(fmt(r.missedSpeech)) | \(fmt(r.falseAlarm)) | \(fmt(r.speakerConfusion)) | \(pct(r.rate)) |"
    }

    private static func pct(_ v: Double) -> String {
        String(format: "%.1f%%", v * 100)
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.2f", v)
    }

    private static func orderedUnique(_ arr: [String]) -> [String] {
        var seen = Set<String>()
        return arr.filter { seen.insert($0).inserted }
    }

    /// Macro-average: sum counts, recompute rate.
    private static func averageWER(_ results: [WERResult]) -> WERResult {
        let refLen = results.map(\.referenceLength).reduce(0, +)
        let s = results.map(\.substitutions).reduce(0, +)
        let i = results.map(\.insertions).reduce(0, +)
        let d = results.map(\.deletions).reduce(0, +)
        return WERResult(referenceLength: refLen, substitutions: s, insertions: i, deletions: d)
    }

    private static func averageDER(_ results: [DERResult]) -> DERResult {
        let total = results.map(\.totalReferenceSpeech).reduce(0, +)
        let missed = results.map(\.missedSpeech).reduce(0, +)
        let fa = results.map(\.falseAlarm).reduce(0, +)
        let conf = results.map(\.speakerConfusion).reduce(0, +)
        return DERResult(totalReferenceSpeech: total, missedSpeech: missed, falseAlarm: fa, speakerConfusion: conf)
    }
}
