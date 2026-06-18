import Foundation

// MARK: - DER result

/// Diarization Error Rate decomposed into components (plan.md M1B.4).
///
/// DER = (missed_speech + false_alarm + speaker_confusion) / total_reference_speech
/// where times are in seconds and all regions are counted at `frameResolution` granularity.
public struct DERResult: Sendable {
    public let totalReferenceSpeech: Double   // seconds
    public let missedSpeech: Double            // seconds — ref has speaker, hyp has none
    public let falseAlarm: Double              // seconds — hyp has speaker, ref has none
    public let speakerConfusion: Double        // seconds — both active but wrong speaker

    /// `(missed + false_alarm + confusion) / total_reference_speech`.
    /// Returns 0.0 when there is no reference speech.
    public var rate: Double {
        guard totalReferenceSpeech > 0 else { return 0.0 }
        return (missedSpeech + falseAlarm + speakerConfusion) / totalReferenceSpeech
    }
}

// MARK: - DER computation

/// Basic Diarization Error Rate over `[SpeakerTurn]` reference vs hypothesis (plan.md M1B.4).
///
/// **Simplifications (documented):**
/// - Single-speaker per frame only — overlap regions are not modelled (each frame counts
///   at most one reference speaker and one hypothesis speaker, like classic DER). A full
///   overlap-aware DER would require multi-label frame scoring (DOVER-Lap style) and is
///   deferred to a later eval pass.
/// - Label permutation is solved greedily: for each reference label the hypothesis label
///   with maximum overlap is assigned. This is optimal for the 2–4 speaker case common
///   in meeting recordings; for N > 8 speakers a full Hungarian-method solve is preferred.
/// - No collar / forgiveness zone. If needed, callers should pre-shrink turns by the
///   desired collar before passing to this function.
///
/// Frame resolution defaults to 10 ms (0.01 s), matching typical diarizer output cadence.
public enum DER {
    /// Default frame resolution in seconds.
    public static let defaultFrameResolution: Double = 0.01

    // MARK: - Public API

    /// Compute DER between `reference` and `hypothesis` turn sequences.
    ///
    /// - Parameters:
    ///   - reference:       Ground-truth speaker turns.
    ///   - hypothesis:      Diarizer output turns.
    ///   - frameResolution: Grid granularity in seconds (default 10 ms).
    public static func compute(
        reference: [SpeakerTurn],
        hypothesis: [SpeakerTurn],
        frameResolution: Double = defaultFrameResolution
    ) -> DERResult {
        guard frameResolution > 0 else {
            return DERResult(totalReferenceSpeech: 0, missedSpeech: 0, falseAlarm: 0, speakerConfusion: 0)
        }

        // Determine the time range to evaluate.
        let allTurns = reference + hypothesis
        guard !allTurns.isEmpty else {
            return DERResult(totalReferenceSpeech: 0, missedSpeech: 0, falseAlarm: 0, speakerConfusion: 0)
        }
        let maxTime = allTurns.map(\.end).max()!
        let frameCount = Int(ceil(maxTime / frameResolution))

        // Build per-frame speaker label arrays (nil = silence).
        let refFrames = frameLabels(from: reference, frameCount: frameCount, resolution: frameResolution)
        let hypFrames = frameLabels(from: hypothesis, frameCount: frameCount, resolution: frameResolution)

        // Compute label mapping: ref → hyp (greedy best-permutation).
        let mapping = greedyMapping(refFrames: refFrames, hypFrames: hypFrames)

        // Count errors.
        var totalRef = 0    // frames with a reference speaker
        var missed = 0      // ref has speaker, hyp silent
        var falseAlarm = 0  // hyp has speaker, ref silent
        var confusion = 0   // both active, wrong mapped label

        for f in 0..<frameCount {
            let r = refFrames[f]
            let h = hypFrames[f]
            switch (r, h) {
            case (nil, nil):
                break
            case (.some, nil):
                totalRef += 1
                missed += 1
            case (nil, .some):
                falseAlarm += 1
            case (.some(let rl), .some(let hl)):
                totalRef += 1
                let expected = mapping[rl]
                if expected != hl {
                    confusion += 1
                }
            }
        }

        let scale = frameResolution
        return DERResult(
            totalReferenceSpeech: Double(totalRef) * scale,
            missedSpeech: Double(missed) * scale,
            falseAlarm: Double(falseAlarm) * scale,
            speakerConfusion: Double(confusion) * scale
        )
    }

    // MARK: - Helpers

    /// Map each frame index to the speaker label active at that time (last-start-wins for overlaps).
    static func frameLabels(
        from turns: [SpeakerTurn],
        frameCount: Int,
        resolution: Double
    ) -> [String?] {
        var frames = [String?](repeating: nil, count: frameCount)
        for turn in turns {
            let startFrame = Int(turn.start / resolution)
            let endFrame = min(Int(ceil(turn.end / resolution)), frameCount)
            for f in startFrame..<endFrame {
                frames[f] = turn.speaker
            }
        }
        return frames
    }

    /// Greedy permutation mapping: reference label → best hypothesis label.
    ///
    /// For each reference label, pick the hypothesis label with the most frame overlap.
    static func greedyMapping(refFrames: [String?], hypFrames: [String?]) -> [String: String] {
        // co-occurrence[refLabel][hypLabel] = frame count
        var co: [String: [String: Int]] = [:]
        for (r, h) in zip(refFrames, hypFrames) {
            guard let rl = r, let hl = h else { continue }
            co[rl, default: [:]][hl, default: 0] += 1
        }

        var mapping: [String: String] = [:]
        for (rl, counts) in co {
            // Assign the hypothesis label with maximum overlap.
            if let best = counts.max(by: { $0.value < $1.value }) {
                mapping[rl] = best.key
            }
        }
        return mapping
    }
}
