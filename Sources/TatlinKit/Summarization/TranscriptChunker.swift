import Foundation

/// Stage 6 input prep (M2.6, research Q6): decide single-pass vs map-reduce and, if needed,
/// split the diarized transcript into chunks **on speaker-segment boundaries** (never
/// mid-segment), targeting ~8–10k tokens per chunk with ~500-token overlap.
///
/// Token counts use the documented `chars / 4` heuristic — good enough for budgeting; the
/// real tokenizer lives in the MLX target and would tighten this. RU/DE are denser than EN,
/// so this slightly *under*-counts non-English, which is the safe direction (smaller chunks).
public enum TranscriptChunker {

    /// `chars / 4` rounded up — a coarse token estimate (documented heuristic, research Q6).
    public static func estimateTokens(_ text: String) -> Int {
        (text.count + 3) / 4
    }

    /// Token estimate for a rendered segment line ("Speaker: text").
    static func segmentTokens(_ seg: AttributedSegment) -> Int {
        estimateTokens(seg.speaker) + estimateTokens(seg.text) + 2  // ": " + newline slack
    }

    /// Thresholds (research Q6). Single-pass below `singlePassLimit`; otherwise chunk to
    /// `targetChunkTokens` with `overlapTokens` carried forward across chunk seams.
    public struct Budget: Sendable {
        public var singlePassLimit: Int
        public var targetChunkTokens: Int
        public var overlapTokens: Int
        public init(singlePassLimit: Int = 28_000, targetChunkTokens: Int = 9_000, overlapTokens: Int = 500) {
            self.singlePassLimit = singlePassLimit
            self.targetChunkTokens = targetChunkTokens
            self.overlapTokens = overlapTokens
        }
    }

    /// A contiguous run of whole segments to summarize in one LLM pass.
    public struct Chunk: Sendable, Equatable {
        public var segments: [AttributedSegment]
        public init(segments: [AttributedSegment]) { self.segments = segments }
        public var estimatedTokens: Int { segments.reduce(0) { $0 + TranscriptChunker.segmentTokens($1) } }
    }

    /// Plan how to summarize `transcript`. One chunk → single-pass; ≥2 → map-reduce.
    /// Splits only at segment boundaries; oversized single segments become their own chunk.
    public static func plan(_ transcript: AlignedTranscript, budget: Budget = Budget()) -> [Chunk] {
        let segments = transcript.segments
        guard !segments.isEmpty else { return [] }

        let total = segments.reduce(0) { $0 + segmentTokens($1) }
        if total <= budget.singlePassLimit {
            return [Chunk(segments: segments)]
        }

        var chunks: [Chunk] = []
        var current: [AttributedSegment] = []
        var currentTokens = 0

        for seg in segments {
            let segTok = segmentTokens(seg)
            // Close the chunk before it exceeds target (but never emit an empty chunk).
            if currentTokens + segTok > budget.targetChunkTokens && !current.isEmpty {
                chunks.append(Chunk(segments: current))
                // Seed the next chunk with trailing overlap segments for continuity.
                let overlap = trailingSegments(current, upTo: budget.overlapTokens)
                current = overlap
                currentTokens = overlap.reduce(0) { $0 + segmentTokens($1) }
            }
            current.append(seg)
            currentTokens += segTok
        }
        if !current.isEmpty { chunks.append(Chunk(segments: current)) }
        return chunks
    }

    /// Take whole segments from the end of `segments` until ~`tokenBudget` is reached.
    static func trailingSegments(_ segments: [AttributedSegment], upTo tokenBudget: Int) -> [AttributedSegment] {
        guard tokenBudget > 0 else { return [] }
        var acc: [AttributedSegment] = []
        var tokens = 0
        for seg in segments.reversed() {
            let t = segmentTokens(seg)
            if tokens + t > tokenBudget && !acc.isEmpty { break }
            acc.append(seg)
            tokens += t
        }
        return acc.reversed()
    }

    /// Render a chunk's segments as the delimited transcript body the prompt wraps as data.
    static func render(_ chunk: Chunk) -> String {
        chunk.segments.map { seg in
            let tag = seg.overlap ? "\(seg.speaker) [overlap]" : seg.speaker
            return "\(tag): \(seg.text)"
        }.joined(separator: "\n")
    }
}
