import AVFoundation
import Foundation

/// Stage 2–7 orchestrator (M2.8, ADR-10/11). Drives a `Session` through transcription →
/// diarization → alignment → speaker-ID → summarization → output using **injected** engines
/// (so it never imports MLX/FluidAudio) sequenced through a `ModelHost` for residency.
///
/// Each stage writes its artifact to the session dir and calls `store.markCompleted(_:)`, so
/// the run is fully re-runnable from any checkpoint via `--from-stage` (crash safety, Q7).
public struct BatchPipeline: Sendable {

    // MARK: - Dependencies

    public let store: SessionStore
    public let asr: any ASREngine
    public let diarizer: any DiarizerEngine
    public let llm: any LLMEngine
    public let host: ModelHost
    public let config: Config

    public init(
        store: SessionStore,
        asr: any ASREngine,
        diarizer: any DiarizerEngine,
        llm: any LLMEngine,
        host: ModelHost = ModelHost(),
        config: Config = Config()
    ) {
        self.store = store
        self.asr = asr
        self.diarizer = diarizer
        self.llm = llm
        self.host = host
        self.config = config
    }

    // MARK: - Config

    /// Which captured channel feeds ASR + diarization.
    public enum AudioSource: String, Sendable, CaseIterable {
        /// Remote meeting (M2.9): ASR both channels and merge on the timeline. Owner words
        /// come from the mic transcript; non-owner words come from the system-channel
        /// transcript aligned against the system-channel diarization. The new default.
        case merged
        /// System-audio channel only (advanced). Loses the owner's voice in remote meetings
        /// because the local mic doesn't bleed into the system output.
        case system
        /// Microphone channel only — in-person meetings where everyone is captured by the
        /// mic and the system channel is silent. Owner-mic VAD is disabled in this mode (the
        /// mic is no longer owner-exclusive); owner identity falls back to enrollment/LLM.
        case mic
    }

    public struct Config: Sendable {
        public var outputLanguage: SummaryPrompt.OutputLanguage
        public var ownerName: String
        public var ownerLabel: String
        public var enrollmentThreshold: Double
        /// Destination vault directory for the final `.md`. Defaults to the session dir.
        public var vaultDirectory: URL?
        public var llmParameters: LLMParameters
        /// Channel that feeds ASR + diarization. Defaults to `.system`.
        public var audioSource: AudioSource
        /// Spoken-language hint for ASR (e.g. "English", "German"). `nil` lets the engine use
        /// its own default. Set from Settings → Spoken language; without it non-English
        /// meetings are biased toward the engine default (ml-reviewer #2).
        public var languageHint: String?

        public init(
            outputLanguage: SummaryPrompt.OutputLanguage = .matchMeeting,
            ownerName: String = "You",
            ownerLabel: String = "Owner",
            enrollmentThreshold: Double = 0.7,
            vaultDirectory: URL? = nil,
            llmParameters: LLMParameters = LLMParameters(),
            audioSource: AudioSource = .merged,
            languageHint: String? = nil
        ) {
            self.outputLanguage = outputLanguage
            self.ownerName = ownerName
            self.ownerLabel = ownerLabel
            self.enrollmentThreshold = enrollmentThreshold
            self.vaultDirectory = vaultDirectory
            self.llmParameters = llmParameters
            self.audioSource = audioSource
            self.languageHint = languageHint
        }
    }

    /// Progress emitted as each stage starts/finishes (simple `@Sendable` callback, M2.8).
    public struct Progress: Sendable {
        public var stage: PipelineStage
        public var message: String
    }

    public typealias ProgressHandler = @Sendable (Progress) -> Void

    // MARK: - Run

    /// Run Stages 2–7 for `sessionID`, optionally resuming from `fromStage` (stages before it
    /// are read from disk, not recomputed). Returns the final vault `.md` URL.
    @discardableResult
    public func run(
        sessionID: String,
        fromStage: PipelineStage = .transcription,
        progress: ProgressHandler = { _ in }
    ) async throws -> URL {
        let session = try store.load(id: sessionID)
        let dir = store.directory(for: sessionID)

        // Stage 2 — Transcription.
        // `.merged` (M2.9) produces two transcripts (transcript-system.json + transcript-mic.json)
        // inside a single withModel block so the ASR weights load once. The single-channel
        // modes keep the legacy transcript.json filename and call shape.
        let systemTranscript: Transcript?
        let micTranscript: Transcript?
        let legacyTranscript: Transcript?
        if shouldRun(.transcription, from: fromStage) {
            progress(Progress(stage: .transcription, message: "Resampling + transcribing"))
            let asrEngine = asr
            let opts = ASROptions(languageHint: config.languageHint, wordTimestamps: true)
            switch config.audioSource {
            case .merged:
                let systemInput = try resampled(session.systemAudioFile, in: dir, sessionID: sessionID)
                let micInput = try resampled(session.micAudioFile, in: dir, sessionID: sessionID)
                let (sys, mic) = try await host.withModel(
                    key: asr.modelID,
                    load: { try await asrEngine.load(); return asrEngine },
                    unload: { await $0.unload() }
                ) { engine in
                    let s = try await engine.transcribe(audioURL: systemInput, options: opts)
                    let m = try await engine.transcribe(audioURL: micInput, options: opts)
                    return (s, m)
                }
                try writeJSON(sys, to: dir.appendingPathComponent("transcript-system.json"))
                try writeJSON(mic, to: dir.appendingPathComponent("transcript-mic.json"))
                systemTranscript = sys
                micTranscript = mic
                legacyTranscript = nil
            case .system, .mic:
                let asrInput = try resampled(primaryAudioFile(session), in: dir, sessionID: sessionID)
                let t = try await host.withModel(
                    key: asr.modelID,
                    load: { try await asrEngine.load(); return asrEngine },
                    unload: { await $0.unload() }
                ) { engine in
                    try await engine.transcribe(audioURL: asrInput, options: opts)
                }
                try writeJSON(t, to: dir.appendingPathComponent("transcript.json"))
                legacyTranscript = t
                systemTranscript = nil
                micTranscript = nil
            }
            try store.markCompleted(.transcription, for: sessionID)
        } else {
            switch config.audioSource {
            case .merged:
                systemTranscript = try readJSON(Transcript.self, from: dir.appendingPathComponent("transcript-system.json"))
                micTranscript = try readJSON(Transcript.self, from: dir.appendingPathComponent("transcript-mic.json"))
                legacyTranscript = nil
            case .system, .mic:
                legacyTranscript = try readJSON(Transcript.self, from: dir.appendingPathComponent("transcript.json"))
                systemTranscript = nil
                micTranscript = nil
            }
        }

        // Stage 3 — Diarization (+ 3b owner intervals on the mic channel).
        // For `.merged`, diarization runs on the system channel (where the non-owner speakers
        // live); the mic channel is owner-only and doesn't need diarization. ownerVAD still
        // contributes a fallback owner-anchor signal even though the mic transcript is the
        // primary owner source.
        let diarInputFile: String = config.audioSource == .merged ? session.systemAudioFile : primaryAudioFile(session)
        let diarization: Diarization
        let ownerIntervals: [WordAligner.Interval]
        if shouldRun(.diarization, from: fromStage) {
            progress(Progress(stage: .diarization, message: "Diarizing speakers"))
            let diarInput = try resampled(diarInputFile, in: dir, sessionID: sessionID)
            let diarEngine = diarizer
            diarization = try await host.withModel(
                key: diarizer.modelID,
                load: { try await diarEngine.load(); return diarEngine },
                unload: { await $0.unload() }
            ) { engine in
                try await engine.diarize(audioURL: diarInput)
            }
            try writeJSON(diarization, to: dir.appendingPathComponent("diarization.json"))
            ownerIntervals = ownerVAD(session: session, in: dir, sessionID: sessionID)
            try store.markCompleted(.diarization, for: sessionID)
        } else {
            diarization = try readJSON(Diarization.self, from: dir.appendingPathComponent("diarization.json"))
            ownerIntervals = ownerVAD(session: session, in: dir, sessionID: sessionID)
        }

        // Stage 4 — Alignment.
        // `.merged` interleaves the two transcripts via WordAligner.alignDual; the
        // single-channel modes go through the original align(transcript:, diarization:, …).
        let aligned: AlignedTranscript
        if shouldRun(.alignment, from: fromStage) {
            progress(Progress(stage: .alignment, message: "Aligning words to speakers"))
            switch config.audioSource {
            case .merged:
                aligned = WordAligner.alignDual(
                    micTranscript: micTranscript!,
                    systemTranscript: systemTranscript!,
                    systemDiarization: diarization,
                    ownerLabel: config.ownerLabel
                )
            case .system, .mic:
                aligned = WordAligner.align(
                    transcript: legacyTranscript!, diarization: diarization,
                    ownerIntervals: ownerIntervals, ownerLabel: config.ownerLabel
                )
            }
            try writeJSON(aligned, to: dir.appendingPathComponent("aligned.json"))
            try store.markCompleted(.alignment, for: sessionID)
        } else {
            aligned = try readJSON(AlignedTranscript.self, from: dir.appendingPathComponent("aligned.json"))
        }

        // Stage 5 — Speaker ID (owner anchor + enrolled embeddings; LLM layer applied in 6).
        // Owner anchor: when mic intervals exist, alignment already stamped those words with
        // `config.ownerLabel`, so resolve THAT label to the owner name. Otherwise fall back to
        // the diarizer label that best overlaps the mic intervals.
        let ownerAnchor: String? = ownerIntervals.isEmpty
            ? bestOverlapLabel(diarization: diarization, intervals: ownerIntervals)
            : config.ownerLabel
        let enrollment = (try? EnrollmentStore(store: store, threshold: config.enrollmentThreshold).load()) ?? [:]
        var resolution = SpeakerResolver.resolve(
            transcript: aligned,
            ownerLabel: ownerAnchor,
            ownerName: config.ownerName,
            embeddings: diarization.embeddings,
            enrollment: enrollment,
            threshold: config.enrollmentThreshold,
            proposals: [],
            roster: session.event?.attendees ?? []
        )
        if shouldRun(.speakerID, from: fromStage) {
            progress(Progress(stage: .speakerID, message: "Resolving speaker identities"))
            try store.markCompleted(.speakerID, for: sessionID)
        }

        // Stage 6 — Summarization (single-pass or map-reduce) → MeetingNotes + LLM proposals.
        // M3.9: prime the model with the series' previous notes + running state, and — on a real
        // run — refresh that running state inside the same loaded-model block.
        let series = loadSeriesContext(for: session)
        let notes: MeetingNotes
        var newSeriesState: String?
        if shouldRun(.summarization, from: fromStage) {
            progress(Progress(stage: .summarization, message: "Summarizing"))
            let result = try await summarize(
                resolution.transcript, roster: session.event?.attendees ?? [],
                seriesBlock: series.promptBlock,
                stateUpdate: series.folderURL != nil ? (series.priorState, session.title) : nil
            )
            notes = result.notes
            newSeriesState = result.newState
            try writeNotesMarkdown(notes, to: dir.appendingPathComponent("notes.md"))
            try store.markCompleted(.summarization, for: sessionID)
        } else {
            // No structured re-parse from notes.md on resume; recompute is cheap relative to ASR.
            // This pass only re-derives speaker proposals — don't refresh series state from it.
            notes = try await summarize(
                resolution.transcript, roster: session.event?.attendees ?? [],
                seriesBlock: series.promptBlock, stateUpdate: nil
            ).notes
        }

        // Re-resolve speakers now that the LLM has proposed names (layer 3), then re-attribute.
        resolution = SpeakerResolver.resolve(
            transcript: aligned,
            ownerLabel: ownerAnchor,
            ownerName: config.ownerName,
            embeddings: diarization.embeddings,
            enrollment: enrollment,
            threshold: config.enrollmentThreshold,
            proposals: notes.speakerNameProposals,
            roster: session.event?.attendees ?? []
        )

        // Stage 7 — Output: compose the vault `.md`.
        progress(Progress(stage: .output, message: "Composing notes"))
        let doc = MarkdownComposer.Document(
            title: session.title,
            date: session.createdAt,
            event: session.event,
            notes: notes,
            transcript: resolution.transcript
        )
        let markdown = MarkdownComposer.render(doc)
        let outURL = outputURL(for: session, series: series)
        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try markdown.write(to: outURL, atomically: true, encoding: .utf8)
        // M3.9 series memory: persist the refreshed running state next to the notes.
        if let folder = series.folderURL, let newSeriesState {
            try? newSeriesState.write(to: folder.appendingPathComponent("state.md"), atomically: true, encoding: .utf8)
        }
        try store.markCompleted(.output, for: sessionID)
        progress(Progress(stage: .output, message: "Wrote \(outURL.lastPathComponent)"))
        return outURL
    }

    // MARK: - Summarization driver

    /// Stage 6 driver. `seriesBlock` (M3.9) is injected into the single-pass / reduce prompt
    /// for continuity; for map-reduce it's added at the reduce step only, to stay in budget.
    /// When `stateUpdate` is set, the running `state.md` is refreshed in the *same* loaded-model
    /// block (no second 30B reload) and returned alongside the notes.
    private func summarize(
        _ transcript: AlignedTranscript,
        roster: [Attendee],
        seriesBlock: String?,
        stateUpdate: (current: String?, title: String)?
    ) async throws -> (notes: MeetingNotes, newState: String?) {
        let chunks = TranscriptChunker.plan(transcript)
        let detected = transcript.language
        let engine = llm
        let params = config.llmParameters
        let lang = config.outputLanguage

        let (raw, newState): (String, String?) = try await host.withModel(
            key: llm.modelID,
            load: { try await engine.load(); return engine },
            unload: { await $0.unload() }
        ) { llm in
            let summaryRaw: String
            if chunks.count <= 1 {
                let body = chunks.first.map(TranscriptChunker.render) ?? ""
                let messages = SummaryPrompt.map(transcriptBody: body, roster: roster, language: lang, detectedLanguage: detected, series: seriesBlock)
                summaryRaw = try await complete(llm, messages, params, language: lang)
            } else {
                // Map-reduce: summarize each chunk, then reduce (series context at reduce only).
                var partials: [String] = []
                for (i, chunk) in chunks.enumerated() {
                    let messages = SummaryPrompt.map(
                        transcriptBody: TranscriptChunker.render(chunk), roster: roster,
                        language: lang, detectedLanguage: detected, chunkIndex: i, chunkCount: chunks.count
                    )
                    partials.append(try await llm.complete(messages: messages, parameters: params))
                }
                let reduceMessages = SummaryPrompt.reduce(partials: partials, roster: roster, language: lang, detectedLanguage: detected, series: seriesBlock)
                summaryRaw = try await complete(llm, reduceMessages, params, language: lang)
            }
            // Stage 6b — fold this meeting into the running series state, same loaded model.
            var newState: String?
            if let stateUpdate {
                let notesMarkdown = MarkdownComposer.notesBody(NotesParser.parse(summaryRaw, language: detected))
                let stateMessages = SummaryPrompt.updateState(
                    currentState: stateUpdate.current, meetingTitle: stateUpdate.title,
                    meetingNotes: notesMarkdown, language: lang
                )
                newState = try await llm.complete(messages: stateMessages, parameters: LLMParameters(maxTokens: 1500))
            }
            return (summaryRaw, newState)
        }
        return (NotesParser.parse(raw, language: detected), newState)
    }

    /// Complete + one validator-driven repair pass (research Q6).
    private func complete(_ llm: any LLMEngine, _ messages: [LLMMessage], _ params: LLMParameters, language: SummaryPrompt.OutputLanguage) async throws -> String {
        let first = try await llm.complete(messages: messages, parameters: params)
        let problems = NotesParser.validate(first)
        guard !problems.isEmpty else { return first }
        let repairMessages = SummaryPrompt.repair(previousOutput: first, problems: problems, language: language)
        let repaired = try await llm.complete(messages: repairMessages, parameters: params)
        // Keep the repair only if it actually validates; else fall back to the first attempt.
        return NotesParser.validate(repaired).isEmpty ? repaired : first
    }

    // MARK: - Owner-mic VAD (Stage 3b)

    /// High-precision owner speech intervals from the mic channel. A simple energy-gate VAD:
    /// frames whose RMS exceeds a fraction of the file's peak RMS are "speech" (documented
    /// heuristic stub — research Q4/Q5; the production VAD lives in the diarizer target).
    /// Returns [] when the mic file is absent or silent.
    private func ownerVAD(session: Session, in dir: URL, sessionID: String) -> [WordAligner.Interval] {
        // Only meaningful when the mic is a separate owner-only channel. In `.mic` mode the
        // mic IS the primary source (everyone in the room), so it can't anchor the owner.
        // `.merged` runs mic-channel ASR directly and doesn't need VAD intervals for the
        // canonical owner attribution, but a fallback owner-anchor signal is still nice for
        // SpeakerID when the mic transcript is empty.
        guard config.audioSource == .system || config.audioSource == .merged else { return [] }
        let micURL = dir.appendingPathComponent(session.micAudioFile)
        guard FileManager.default.fileExists(atPath: micURL.path) else { return [] }
        guard let file = try? AVAudioFile(forReading: micURL) else { return [] }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              (try? file.read(into: buffer)) != nil,
              let samples = buffer.floatChannelData?[0]
        else { return [] }

        let n = Int(buffer.frameLength)
        let sr = format.sampleRate
        let windowFrames = max(1, Int(sr * 0.1))  // 100 ms windows.

        // First pass: per-window RMS + global peak.
        var rms: [Double] = []
        var peak = 0.0
        var i = 0
        while i < n {
            let end = min(i + windowFrames, n)
            var sum = 0.0
            for j in i..<end { sum += Double(samples[j]) * Double(samples[j]) }
            let r = (sum / Double(end - i)).squareRoot()
            rms.append(r)
            peak = max(peak, r)
            i = end
        }
        guard peak > 0 else { return [] }
        let gate = peak * 0.15  // speech = ≥15% of peak window energy.

        // Second pass: coalesce consecutive speech windows into intervals.
        var intervals: [WordAligner.Interval] = []
        var runStart: Int?
        for (w, r) in rms.enumerated() {
            if r >= gate {
                if runStart == nil { runStart = w }
            } else if let s = runStart {
                intervals.append(interval(s, w, windowFrames: windowFrames, sr: sr))
                runStart = nil
            }
        }
        if let s = runStart { intervals.append(interval(s, rms.count, windowFrames: windowFrames, sr: sr)) }
        return intervals
    }

    private func interval(_ startWindow: Int, _ endWindow: Int, windowFrames: Int, sr: Double) -> WordAligner.Interval {
        WordAligner.Interval(
            start: Double(startWindow * windowFrames) / sr,
            end: Double(endWindow * windowFrames) / sr
        )
    }

    /// Diarizer label whose turns overlap the owner intervals the most (the owner anchor).
    func bestOverlapLabel(diarization: Diarization, intervals: [WordAligner.Interval]) -> String? {
        guard !intervals.isEmpty else { return nil }
        var perLabel: [String: TimeInterval] = [:]
        for turn in diarization.turns {
            for iv in intervals {
                perLabel[turn.speaker, default: 0] += WordAligner.overlap(turn.start, turn.end, iv.start, iv.end)
            }
        }
        return perLabel.filter { $0.value > 0 }.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }?.key
    }

    // MARK: - Audio prep

    /// Relative filename of the channel that feeds ASR + diarization in single-channel modes.
    /// For `.merged`, ASR runs on both channels and diarization runs on the system channel;
    /// callers that still want a single name use this and treat the system channel as primary.
    private func primaryAudioFile(_ session: Session) -> String {
        switch config.audioSource {
        case .system, .merged: return session.systemAudioFile
        case .mic:             return session.micAudioFile
        }
    }

    /// Produce (or reuse) the 16 kHz mono input for a session WAV. Resamples once into the
    /// session dir as `<name>-16k.wav` so re-runs reuse it.
    private func resampled(_ relativeName: String, in dir: URL, sessionID: String) throws -> URL {
        let source = dir.appendingPathComponent(relativeName)
        let outName = (relativeName as NSString).deletingPathExtension + "-16k.wav"
        let out = dir.appendingPathComponent(outName)
        if !FileManager.default.fileExists(atPath: out.path) {
            try AudioResampler.resample(input: source, output: out)
        }
        return out
    }

    // MARK: - Output location + series memory (M3.9)

    /// Per-session continuity context: the series subfolder (when a vault is set), the previous
    /// meeting's notes, the running `state.md`, and the assembled summariser prompt block.
    private struct SeriesContext: Sendable {
        var folderURL: URL?
        var priorNotes: String?
        var priorState: String?
        var promptBlock: String?
    }

    private func loadSeriesContext(for session: Session) -> SeriesContext {
        let inSeries = ((try? store.list()) ?? []).filter { $0.seriesKey == session.seriesKey }
        // Folder name is pinned to the earliest session's title, so a later rename doesn't fork it.
        let earliest = inSeries.min { $0.createdAt < $1.createdAt } ?? session
        let folderName = MarkdownComposer.sanitize(earliest.event?.title ?? earliest.title)
        let folderURL: URL? = config.vaultDirectory.flatMap { vault in
            folderName.isEmpty ? nil : vault.appendingPathComponent(folderName, isDirectory: true)
        }
        // Previous meeting = most recent OTHER session in the series whose notes exist on disk.
        let prior = inSeries
            .filter { $0.id != session.id }
            .sorted { $0.createdAt > $1.createdAt }
            .first { FileManager.default.fileExists(atPath: store.directory(for: $0.id).appendingPathComponent("notes.md").path) }
        let priorNotes = prior.flatMap {
            try? String(contentsOf: store.directory(for: $0.id).appendingPathComponent("notes.md"), encoding: .utf8)
        }
        let priorState = folderURL.flatMap {
            try? String(contentsOf: $0.appendingPathComponent("state.md"), encoding: .utf8)
        }
        return SeriesContext(
            folderURL: folderURL,
            priorNotes: priorNotes,
            priorState: priorState,
            promptBlock: SummaryPrompt.seriesContextBlock(priorState: priorState, priorNotes: priorNotes)
        )
    }

    private func outputURL(for session: Session, series: SeriesContext) -> URL {
        let name = MarkdownComposer.filename(title: session.event?.title ?? session.title, date: session.createdAt)
        let base = series.folderURL ?? config.vaultDirectory ?? store.directory(for: session.id)
        return base.appendingPathComponent(name)
    }

    // MARK: - Stage gating + JSON I/O

    private func shouldRun(_ stage: PipelineStage, from: PipelineStage) -> Bool {
        order(stage) >= order(from)
    }

    private func order(_ stage: PipelineStage) -> Int {
        PipelineStage.allCases.firstIndex(of: stage) ?? 0
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    private func writeNotesMarkdown(_ notes: MeetingNotes, to url: URL) throws {
        try MarkdownComposer.notesBody(notes).write(to: url, atomically: true, encoding: .utf8)
    }
}
