import Foundation

// MARK: - WER result

/// Word Error Rate result with per-operation counts (plan.md M1B.3).
public struct WERResult: Sendable {
    /// Words in the reference sequence.
    public let referenceLength: Int
    public let substitutions: Int
    public let insertions: Int
    public let deletions: Int

    /// `(S + D + I) / N` — can exceed 1.0 for very bad hypotheses.
    public var rate: Double {
        guard referenceLength > 0 else { return insertions == 0 ? 0.0 : 1.0 }
        return Double(substitutions + insertions + deletions) / Double(referenceLength)
    }
}

// MARK: - WER computation

/// Token-normalized WER implementation (plan.md M1B.3, Part D).
///
/// Normalization: lowercase, strip punctuation, collapse whitespace, then split on spaces.
/// Edit distance is standard Levenshtein (substitution cost = 1) over token sequences.
public enum WER {
    // MARK: - Public API

    /// Compute WER between `reference` and `hypothesis` strings.
    public static func compute(reference: String, hypothesis: String) -> WERResult {
        let ref = tokenize(reference)
        let hyp = tokenize(hypothesis)
        return compute(referenceTokens: ref, hypothesisTokens: hyp)
    }

    /// Compute WER from pre-tokenized arrays (useful for testing specific token lists).
    public static func compute(referenceTokens ref: [String], hypothesisTokens hyp: [String]) -> WERResult {
        let (s, i, d) = levenshteinCounts(ref: ref, hyp: hyp)
        return WERResult(referenceLength: ref.count, substitutions: s, insertions: i, deletions: d)
    }

    // MARK: - Tokenization

    /// Lowercase → strip punctuation → collapse whitespace → split.
    static func tokenize(_ text: String) -> [String] {
        let lower = text.lowercased()
        // Remove characters that are not alphanumeric, whitespace, or hyphen (for compound words).
        let stripped = lower.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-'"))
                .contains(scalar)
        }
        let joined = String(stripped)
        return joined.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - Levenshtein with operation counts

    /// Returns (substitutions, insertions, deletions) via dynamic programming.
    /// Space complexity O(|hyp|); time O(|ref| × |hyp|).
    static func levenshteinCounts(ref: [String], hyp: [String]) -> (Int, Int, Int) {
        let n = ref.count
        let m = hyp.count

        if n == 0 { return (0, m, 0) }
        if m == 0 { return (0, 0, n) }

        // dp[j] = (editDistance, substitutions, insertions, deletions) up to ref[i], hyp[j].
        typealias Cell = (dist: Int, s: Int, i: Int, d: Int)

        var prev: [Cell] = (0...m).map { j in (j, 0, j, 0) }
        var curr: [Cell] = Array(repeating: (0, 0, 0, 0), count: m + 1)

        for ri in 1...n {
            curr[0] = (ri, 0, 0, ri)
            for hi in 1...m {
                if ref[ri - 1] == hyp[hi - 1] {
                    curr[hi] = prev[hi - 1]  // Match — no cost.
                } else {
                    let sub = (prev[hi - 1].dist + 1, prev[hi - 1].s + 1, prev[hi - 1].i, prev[hi - 1].d)
                    let ins = (curr[hi - 1].dist + 1, curr[hi - 1].s, curr[hi - 1].i + 1, curr[hi - 1].d)
                    let del = (prev[hi].dist + 1, prev[hi].s, prev[hi].i, prev[hi].d + 1)
                    // Pick the minimum-edit-distance option; tie-break: sub < del < ins.
                    if sub.0 <= ins.0, sub.0 <= del.0 {
                        curr[hi] = sub
                    } else if del.0 <= ins.0 {
                        curr[hi] = del
                    } else {
                        curr[hi] = ins
                    }
                }
            }
            swap(&prev, &curr)
        }

        let final = prev[m]
        return (final.s, final.i, final.d)
    }
}
