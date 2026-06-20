import Foundation

/// Stage 4 (M2.4, ADR-4 / research Q4): whisperX-style word-level max-overlap assignment.
///
/// For each ASR `Word [start,end]` we accumulate temporal intersection per diarizer
/// speaker across the turns it touches, then assign the argmax speaker. When a word
/// overlaps no turn at all we fall back to the nearest turn. Words whose range intersects
/// ≥2 distinct active speaker turns are flagged `overlap = true` (low-confidence).
///
/// Owner intervals (from a clean mic-channel VAD, Stage 3b) take precedence: any word
/// whose range intersects an owner interval is force-assigned to `ownerLabel`, overriding
/// the diarizer (research Q4 "owner-mic channel merge").
///
/// Turns are sorted once and scanned via a binary-search lower bound, so the per-word cost
/// is O(log n + k) (k = turns touching the word), not O(n·m) over the whole file.
public enum WordAligner {

    // MARK: - Public API

    /// Attribute `transcript` words to diarizer speakers, applying owner precedence, and
    /// regroup the result into display segments.
    ///
    /// - Parameters:
    ///   - transcript:     Stage-2 output (must carry word timestamps).
    ///   - diarization:    Stage-3 output (speaker turns).
    ///   - ownerIntervals: High-precision owner speech intervals from the mic channel
    ///                     (Stage 3b VAD). May be empty.
    ///   - ownerLabel:     Label to force-assign within `ownerIntervals` (e.g. "Owner").
    public static func align(
        transcript: Transcript,
        diarization: Diarization,
        ownerIntervals: [Interval] = [],
        ownerLabel: String = "Owner"
    ) -> AlignedTranscript {
        // Sort turns once; build a parallel array of start times for binary search.
        let turns = diarization.turns.sorted { $0.start < $1.start }
        let starts = turns.map(\.start)
        // Largest turn end seen up to each index — lets the scan stop early without missing
        // a long earlier turn that still overlaps a late word.
        var maxEndPrefix = [TimeInterval](repeating: 0, count: turns.count)
        var runningMax = -TimeInterval.infinity
        for (i, t) in turns.enumerated() {
            runningMax = max(runningMax, t.end)
            maxEndPrefix[i] = runningMax
        }

        let owner = ownerIntervals.sorted { $0.start < $1.start }

        let words = transcript.words
        var attributed: [AttributedWord] = []
        attributed.reserveCapacity(words.count)

        for word in words {
            // Owner precedence: any intersection with an owner interval wins outright.
            if intersectsAny(word.start, word.end, intervals: owner) {
                attributed.append(AttributedWord(word: word, speaker: ownerLabel, overlap: false))
                continue
            }

            // Accumulate overlap per speaker across all touching turns.
            var perSpeaker: [String: TimeInterval] = [:]
            var distinctActive = Set<String>()
            for idx in touchingTurnIndices(word.start, word.end, turns: turns, starts: starts, maxEndPrefix: maxEndPrefix) {
                let turn = turns[idx]
                let ov = overlap(word.start, word.end, turn.start, turn.end)
                guard ov > 0 else { continue }
                perSpeaker[turn.speaker, default: 0] += ov
                distinctActive.insert(turn.speaker)
            }

            let speaker: String
            if let best = perSpeaker.max(by: { lhs, rhs in
                // Tie-break on label so the result is deterministic.
                lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
            }) {
                speaker = best.key
            } else {
                // No overlap anywhere → nearest turn by gap to the word midpoint.
                speaker = nearestTurn(word, turns: turns)?.speaker ?? unknownLabel
            }

            attributed.append(
                AttributedWord(word: word, speaker: speaker, overlap: distinctActive.count >= 2)
            )
        }

        let segments = regroup(attributed)
        return AlignedTranscript(language: transcript.language, words: attributed, segments: segments)
    }

    // MARK: - Dual-channel merge (M2.9)

    /// Merge two channel-specific ASR passes onto a single timeline.
    ///
    /// Used by `BatchPipeline` when `AudioSource == .merged`:
    /// - `micTranscript` is owner-only (headphones assumed): every word is force-tagged with
    ///   `ownerLabel`.
    /// - `systemTranscript` is the non-owner channel: aligned word-by-word against
    ///   `systemDiarization` via the single-channel `align(...)` (no owner-interval pass —
    ///   the mic is now the authoritative owner channel, system-side owner-precedence would
    ///   only re-stamp non-owner words to "Owner" by mistake).
    ///
    /// The two streams are then interleaved by `word.start`. Where mic and system words
    /// share time (the owner talked over a remote participant or vice versa), both sides
    /// get `overlap = true`. The resulting `AlignedTranscript.segments` are regrouped so
    /// switching speakers between channels produces clean break points.
    public static func alignDual(
        micTranscript: Transcript,
        systemTranscript: Transcript,
        systemDiarization: Diarization,
        ownerLabel: String = "Owner"
    ) -> AlignedTranscript {
        // Mic words → all owner. Cheap, no diarization needed.
        let micAttributed: [AttributedWord] = micTranscript.words.map {
            AttributedWord(word: $0, speaker: ownerLabel, overlap: false)
        }

        // System words through the standard single-channel aligner. No owner intervals on
        // this side — mic is the canonical owner channel.
        let systemAttributed = align(
            transcript: systemTranscript,
            diarization: systemDiarization,
            ownerIntervals: [],
            ownerLabel: ownerLabel
        ).words

        // Cross-channel overlap: any mic word whose interval intersects any system word
        // (or vice versa) gets overlap-flagged on both sides.
        let (mic2, system2) = tagCrossChannelOverlap(mic: micAttributed, system: systemAttributed)

        // Stable merge by start time. When starts tie, mic first — keeps owner ordering
        // deterministic if both channels yielded a word at exactly t=0 etc.
        var merged = mic2 + system2
        merged.sort { lhs, rhs in
            if lhs.word.start != rhs.word.start { return lhs.word.start < rhs.word.start }
            return lhs.speaker == ownerLabel && rhs.speaker != ownerLabel
        }

        let segments = regroup(merged)
        let language = micTranscript.language ?? systemTranscript.language
        return AlignedTranscript(language: language, words: merged, segments: segments)
    }

    /// Flag mic words and system words that occupy the same time as `overlap=true`.
    /// `mic` is treated as the smaller/scanning side; `system` is sorted and searched.
    static func tagCrossChannelOverlap(
        mic: [AttributedWord],
        system: [AttributedWord]
    ) -> (mic: [AttributedWord], system: [AttributedWord]) {
        guard !mic.isEmpty, !system.isEmpty else { return (mic, system) }

        // Sort system by word.start to enable lower-bound search, but track original
        // positions so we can flip overlap on the caller's order if it ever matters.
        let sortedSystem = system.enumerated().sorted { $0.element.word.start < $1.element.word.start }
        let starts = sortedSystem.map(\.element.word.start)

        var newMic = mic
        var systemOverlapOriginalIndices = Set<Int>()

        for i in newMic.indices {
            let m = newMic[i].word
            // Walk back from the lower bound to include any system word that started
            // earlier but is still ongoing when the mic word fires.
            var j = lowerBound(starts, m.start)
            while j > 0 && sortedSystem[j - 1].element.word.end >= m.start { j -= 1 }
            while j < sortedSystem.count && sortedSystem[j].element.word.start <= m.end {
                let sWord = sortedSystem[j].element.word
                if overlap(m.start, m.end, sWord.start, sWord.end) > 0 {
                    newMic[i].overlap = true
                    systemOverlapOriginalIndices.insert(sortedSystem[j].offset)
                }
                j += 1
            }
        }

        var newSystem = system
        for idx in systemOverlapOriginalIndices { newSystem[idx].overlap = true }
        return (newMic, newSystem)
    }

    // MARK: - Owner intervals

    /// A half-open-ish time interval `[start, end]` (seconds), inclusive of touching edges.
    public struct Interval: Sendable, Equatable {
        public var start: TimeInterval
        public var end: TimeInterval
        public init(start: TimeInterval, end: TimeInterval) {
            self.start = start
            self.end = end
        }
    }

    // MARK: - Regrouping

    /// Collapse consecutive same-speaker attributed words into `AttributedSegment`s.
    /// A segment is `overlap` if any of its words was overlap-flagged.
    static func regroup(_ words: [AttributedWord]) -> [AttributedSegment] {
        var segments: [AttributedSegment] = []
        for aw in words {
            if var last = segments.last, last.speaker == aw.speaker {
                last.end = aw.word.end
                last.text = last.text.isEmpty ? aw.word.text : last.text + " " + aw.word.text
                last.overlap = last.overlap || aw.overlap
                segments[segments.count - 1] = last
            } else {
                segments.append(
                    AttributedSegment(
                        speaker: aw.speaker,
                        start: aw.word.start,
                        end: aw.word.end,
                        text: aw.word.text,
                        overlap: aw.overlap
                    )
                )
            }
        }
        return segments
    }

    // MARK: - Geometry

    static let unknownLabel = "Speaker ?"

    /// Length of the temporal intersection of `[a0,a1]` and `[b0,b1]` (0 if disjoint).
    static func overlap(_ a0: TimeInterval, _ a1: TimeInterval, _ b0: TimeInterval, _ b1: TimeInterval) -> TimeInterval {
        max(0, min(a1, b1) - max(a0, b0))
    }

    /// Indices of sorted turns whose range intersects `[ws,we]`. Uses a binary search to
    /// find the first candidate, then scans forward while later turns can still start before
    /// the word ends. The `maxEndPrefix` guard pulls in long earlier turns that begin before
    /// the lower bound but still overlap.
    static func touchingTurnIndices(
        _ ws: TimeInterval, _ we: TimeInterval,
        turns: [SpeakerTurn], starts: [TimeInterval], maxEndPrefix: [TimeInterval]
    ) -> [Int] {
        guard !turns.isEmpty else { return [] }
        // First turn that could overlap: scan back from the lower bound while an earlier
        // turn's running-max end still reaches past `ws`.
        var lo = lowerBound(starts, ws)
        while lo > 0 && maxEndPrefix[lo - 1] >= ws { lo -= 1 }

        var result: [Int] = []
        var i = lo
        while i < turns.count && turns[i].start <= we {
            if turns[i].end >= ws { result.append(i) }
            i += 1
        }
        return result
    }

    /// First index whose start is ≥ `value` (standard lower-bound binary search).
    static func lowerBound(_ sorted: [TimeInterval], _ value: TimeInterval) -> Int {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// True if `[a0,a1]` intersects any interval in the (start-sorted) list.
    static func intersectsAny(_ a0: TimeInterval, _ a1: TimeInterval, intervals: [Interval]) -> Bool {
        for iv in intervals {
            if iv.start > a1 { break }            // sorted: nothing later can overlap
            if overlap(a0, a1, iv.start, iv.end) > 0 { return true }
        }
        return false
    }

    /// Nearest turn to a word with no overlap, by gap to the word midpoint.
    static func nearestTurn(_ word: Word, turns: [SpeakerTurn]) -> SpeakerTurn? {
        guard !turns.isEmpty else { return nil }
        let mid = (word.start + word.end) / 2
        return turns.min { lhs, rhs in gap(mid, lhs) < gap(mid, rhs) }
    }

    private static func gap(_ t: TimeInterval, _ turn: SpeakerTurn) -> TimeInterval {
        if t < turn.start { return turn.start - t }
        if t > turn.end { return t - turn.end }
        return 0
    }
}
