# Tatlin — Architecture & Implementation Plan

> Companion to `research.md` (Phase 0, signed off 2026-06-16). This is the **Plan** deliverable: an ADR + a phased, milestone-driven build plan. Annotate inline; nothing is built until this is approved.

---

## Part A — Architecture Decision Record (ADR)

### Context
Local-first, on-device, **batch** (non-real-time) macOS meeting note-taker. Swift-native, Apple-Silicon only (M5 Pro / 64 GB), macOS 26 Tahoe. Output = Obsidian-friendly Markdown to a synced folder. Single technical user. Full rationale + citations in `research.md`.

### Decisions (locked)

| # | Decision | Source |
|---|---|---|
| ADR-1 | **Capture:** `ScreenCaptureKit` `SCStream`, system + mic as separate streams → two mono 48 kHz/32-bit-float WAVs per session. Resample to 16 kHz mono at ASR time. | research Q1 |
| ADR-2 | **ASR:** **Parakeet-TDT-0.6B-v3** via `mlx-audio-swift` (native word timestamps) as primary; bake-off vs Voxtral-Mini-4B-Realtime-fp16; WhisperKit large-v3 as hard fallback. | research Q2/D1 |
| ADR-3 | **Diarization:** **FluidAudio** `OfflineDiarizerManager` → pyannote community-1 (offline, overlap-aware, CoreML/ANE). | research Q3/D2 |
| ADR-4 | **Alignment:** whisperX-style word-level max-overlap assignment + interval-tree lookup; owner-mic channel merged by precedence. | research Q4 |
| ADR-5 | **Speaker ID:** layered — owner-mic anchor → enrolled embeddings → LLM relabel (evidence-gated). | research Q5 |
| ADR-6 | **Summarization:** `Qwen3-30B-A3B-Instruct-2507-MLX-8bit` in-process via `mlx-swift-lm` (MLXLLM); Markdown-first prompting (no constrained decoding); sequential model load/unload. | research Q6/D3 |
| ADR-7 | **Output:** YAML front-matter + structured notes + full diarized transcript → configured synced folder; stable `timestamp[-title].md` filenames. | brief §5.5 |
| ADR-8 | **Packaging:** SwiftUI `MenuBarExtra` + `SMAppService.mainApp` login item, `LSUIElement=YES`; models downloaded on first run into Application Support. | research Q7 |

### Cross-cutting decisions to ratify in this plan
- **ADR-9 — Distribution: Developer-ID-signed + notarized `.app`, shipped via GitHub Releases (later a Homebrew cask), NOT Mac App Store.** ✅ confirmed. **Sandbox ON** (amended 2026-06-19 — see ADR-9a below). Rationale for direct distribution: ~15–25 GB model downloads break the App Store size/ODR model; screen-recording + system-audio is review friction. Build a notarized `.app` in a `.dmg`/zip for the Releases page; add a `Casks/tatlin.rb` Homebrew cask once releases stabilize.
- **ADR-9a — App Sandbox: ON (amended 2026-06-19).** Earlier sketch was "sandbox off for simplicity"; the chosen path is sandbox ON with a minimal entitlement set, accepting the data-isolation consequence (the app's `Application Support` is redirected to `~/Library/Containers/<bundle-id>/Data/Library/Application Support/`). Enabled capabilities: **Audio Input** (`com.apple.security.device.audio-input`, mic capture via SCStream), **Outgoing Network** (`com.apple.security.network.client`, model downloads from Hugging Face), **Calendars** (`com.apple.security.personal-information.calendars`, EventKit read-only, ADR-13), **User-Selected File: Read/Write** (vault folder writes via `NSOpenPanel` + security-scoped bookmark). Hardened Runtime stays ON for notarization. Screen Recording / system audio is granted via TCC at first use; no sandbox checkbox controls it. **Consequence:** the menubar app and the CLI keep *separate* `Application Support` roots — same on-disk layout, different physical locations — see ADR-10.
- **ADR-10 — Two front doors over one core library, with separate data stores.** A SwiftPM package (`TatlinKit` + `TatlinML` libraries) holds all pipeline logic; a **CLI harness** (`tatlin`, SwiftPM executable at `Sources/tatlin/`) and the **menubar app** (`Tatlin`, a hand-managed Xcode project at `Tatlin/Tatlin.xcodeproj/` with sources in `Tatlin/Tatlin/`) are thin shells over it. The app is an Xcode-managed `.app` bundle rather than a SwiftPM executable because it needs `LSUIElement`, entitlements, and Developer-ID signing/notarization (ADR-9/9a) — things SwiftPM doesn't model. **Data-store split (consequence of ADR-9a):** because `FileManager.applicationSupportDirectory` is sandbox-aware, the same `SessionStore` / `ModelStore` code returns *different physical roots* in the two contexts — the app sees its container at `~/Library/Containers/dev.kalambet.apps.Tatlin/Data/Library/Application Support/dev.kalambet.tatlin/`, the CLI sees the user-domain `~/Library/Application Support/dev.kalambet.tatlin/`. They share **no state** at runtime. The CLI remains the dev/eval surface (Phase 1B Stage 5 bake-off, `--from-stage` debug, `tatlin eval`); the app is what users use. Model weights download independently into each store (a `tatlin clean` subcommand exists to wipe the CLI side, see Phase 1B). Bundle ids: CLI = `dev.kalambet.tatlin`, app = `dev.kalambet.apps.Tatlin` (app's TCC + container scope; the inner `dev.kalambet.tatlin/` directory name is the shared schema folder).
- **ADR-11 — Model lifecycle is an actor.** A single `ModelHost` actor owns download/verify/compile/load/unload and enforces **strict sequential residency** (only one heavy model resident at a time). Prevents the 64 GB ceiling breach (research risk #6).
- **ADR-12 — Swift 6 structured concurrency**, `async/await` + actors for orchestration; no Combine for pipeline flow. `@Observable` for app view-models.
- **ADR-13 — Calendar metadata, read-only, no automation.** On **capture start**, query `EventKit` for events overlapping *now*; capture title, attendees, notes, start/end into `session.json`. **No auto start/stop, no segmentation, no event↔recording matching heuristics** — the user clicks Start, we snapshot whatever meeting is on the calendar at that instant. Attendee roster becomes a prior for speaker ID (ADR-5). Calendar-*driven automation* stays out of scope entirely. *(Spoken-language is NOT derived from calendar — see Part F.)*
  - **Non-meeting filter:** skip events that are **all-day**, have `EKEventAvailability` of `.free`/`.unavailable`, or whose title matches the **user-editable skip-list in Settings** (defaults: `Out of Office`, `OOO`, `Focus Time`, `Focus`, `Busy`). These are never treated as meetings. (Skip-list shares the Settings page with the vault path — see M3.6.)
  - **Candidate resolution:** after filtering — **0 candidates →** timestamped default name; **1 →** use silently; **≥2 →** show a small **picker window** at Start listing the candidates (title, time, attendee count) + a "None / custom name" option. Selection is required before capture metadata is finalized (capture itself can begin immediately; metadata attaches on pick).

---

## Part B — System Architecture

### Pipeline (batch; stages 2–5 triggered when capture stops)
```
[0 Start]    user clicks Start → EventKit snapshot of current event → session.json
     ▼            (title, attendees roster, notes; else timestamped default)
[1 Capture]  SCStream → raw-system.wav + raw-mic.wav        (live, only real-time stage)
     │  (session boundary = user stops)
     ▼
[2 Transcribe]  resample 16k → Parakeet → words+timestamps  (transcript.json)
     ▼
[3 Diarize]    FluidAudio community-1 → speaker turns        (diarization.json)
   [3b OwnerVAD] VAD on mic channel → high-precision owner intervals
     ▼
[4 Align]      word×turn max-overlap + owner-precedence merge (aligned.json)
     ▼
[5 SpeakerID]  owner anchor → enrolled embeddings → (defer LLM relabel to 6)
     ▼
[6 Summarize]  Qwen3-30B-A3B → structured Markdown + speaker_name_map  (notes.md)
     ▼
[7 Output]     YAML front-matter + notes + diarized transcript → Obsidian vault
```
Each stage reads the prior artifact from the session dir and writes its own → **fully re-runnable** from any checkpoint (crash safety, research Q7).

### Package / target layout
```
tatlin/                                  (git repo root + SwiftPM package root)
  Package.swift                          SwiftPM manifest (TatlinKit, TatlinML, tatlin CLI)
  Tatlin.xcodeproj/                      Xcode project — hosts the menubar app target only
  Tatlin/                                app sources + bundle resources (loaded by Xcode project)
    TatlinApp.swift                      @main entry — MenuBarExtra + Settings scenes
    AppModel.swift                       capture + pipeline driver (@Observable, @MainActor)
    MenuContentView.swift                menubar panel view
    SettingsView.swift                   Settings window (vault path / language / owner / source)
    Info.plist                           LSUIElement=YES + NSMicrophone/Calendars/Camera usage strings
    Tatlin.entitlements                  sandbox ON (ADR-9a): audio-input + outgoing-network +
                                         calendars + user-selected RW; hardened-runtime ON
    Assets.xcassets/                     app icon + accent color
  Sources/
    TatlinKit/                           library — pipeline logic, platform-only deps (Apple frameworks)
      Session/        SessionStore, artifact codables, resume logic
      Calendar/       CalendarService (EventKit, read-only), current-event snapshot, roster
      Capture/        SCStreamRecorder, AudioFileWriter, dual-channel WAV
      Audio/          AVAudioConverter resampling (48k→16k mono)
      Transcription/  ASREngine protocol + Transcript model
      Diarization/    DiarizerEngine protocol + Diarization model
      Alignment/      word×turn assignment, interval tree, overlap flagging
      SpeakerID/      anchor resolver, embedding enrollment store
      Summarization/  LLMEngine protocol, prompt templates, NotesParser, MeetingNotes
      Output/         MarkdownComposer, front-matter, vault writer
      Models/         ModelHost actor, ModelManifest, downloader, SHA-256, CoreML compile
      Pipeline/       BatchPipeline orchestrator (stages 2–7), Progress events
      Engines/        StubEngines (CLI/test fast path)
      Eval/           WER / DER / EvalReport
    TatlinML/                            library — concrete ML engines (ParakeetEngine, VoxtralEngine,
                                         WhisperKitEngine, FluidDiarizer, QwenSummarizer) +
                                         MLEngineFactory. Pulls the MLX/Metal transitive graph.
    tatlin/                              executable — `tatlin` CLI (record / run / models / eval / …)
  Tests/
    TatlinKitTests/                      Swift Testing — units for the above
```

### Key dependencies (pin exact versions in Phase 1)
- `ml-explore/mlx-swift`, `ml-explore/mlx-swift-lm` (MLXLLM/MLXLMCommon) — Qwen3 MoE summarizer
- `Blaizzy/mlx-audio-swift` — Parakeet ASR (and Voxtral for the bake-off)
- `FluidInference/FluidAudio` — diarization + embeddings
- `argmaxinc/WhisperKit` — ASR fallback (optional, behind a flag)
- `orchetect/MenuBarExtraAccess` — only if NSStatusItem access needed for the dual-state icon
- `apple/swift-argument-parser` — CLI

### Core protocols (stable seams for the bake-off / fallbacks)
```swift
protocol ASREngine {            // ParakeetEngine | VoxtralEngine | WhisperKitEngine
  func transcribe(_ url: URL, options: ASROptions) async throws -> Transcript  // words + timestamps
}
protocol DiarizerEngine { func diarize(_ url: URL) async throws -> Diarization } // turns + embeddings
protocol LLMEngine { func summarize(_ prompt: Prompt) async throws -> String }
actor ModelHost {               // ADR-11: one heavy model resident at a time
  func withASR<T>(_ body: (ASREngine) async throws -> T) async throws -> T
  func withDiarizer<T>(...) ; func withLLM<T>(...)
}
```

---

## Part C — Phased Implementation Plan

> Order optimizes for de-risking. Phase 1 (capture) and Phase 1B (model infra + eval) run in **parallel** — the eval harness needs only sample audio (QuickTime/existing recordings), not the real recorder.

### Phase 1 — Capture spike  *(riskiest macOS unknown)*
**Status (2026-06-18): code-complete & building; on-device run pending.** SwiftPM workspace, `SessionStore`, `AudioResampler`, `AudioFileWriter`, `SCStreamRecorder` (actor + watchdog), `CalendarService` (+pure filter logic), and `record`/`calendar` CLI subcommands landed; 33 unit tests green. **Remaining:** exercise live capture + TCC grants on the M5 (M1.4 acceptance) — cannot run in CI.
**Goal:** headless dual-channel recorder writing clean session files; permissions verified end-to-end.
- M1.1 `git init`; SwiftPM scaffold; `tatlin record` subcommand.
- M1.2 `SCStreamRecorder`: `capturesAudio + captureMicrophone`, separate `.audio`/`.microphone` outputs → two `AudioWriter`s (independent timestamp baselines) → `raw-system.wav` + `raw-mic.wav` (48 kHz/32-bit float mono).
- M1.3 `SessionStore`: create `~/…/Tatlin/sessions/<ISO8601>/` + `session.json` on record-start; flush-on-write.
- M1.4 Permission flow probe: mic (`AVCaptureDevice`) + screen/system-audio (`SCShareableContent`); handle relaunch-after-grant.
- M1.5 Stability: stalled-callback watchdog → restart stream + flush (research Q1 risk).
- M1.6 `CalendarService` (ADR-13): on Start, read-only `EventKit` snapshot of events overlapping now → apply non-meeting filter (all-day / `.free`/`.unavailable` availability / OOO+Focus title heuristics) → title, attendees (name+email), notes, start/end → `session.json`. Resolution: 0 → timestamped default (`Tatlin YYYY-MM-DD HHmm`); 1 → silent; ≥2 → **picker window** (title/time/attendee-count + "None / custom name"). Degrades silently if calendar permission absent. (Picker UI itself lands in Phase 3; CLI/headless path uses 0/1-candidate logic + a `--event-id` flag for ≥2.)
- **Acceptance:** record a real 30-min Zoom/Meet/in-person session; both WAVs valid & independently playable; owner clearly isolated on mic channel; survives app kill mid-session (partial WAVs still valid); AirPods-mic path tested; starting during a scheduled meeting captures the right event metadata, and starting with no meeting yields a clean default name.

> **Data-store split note (ADR-9a/ADR-10).** From this phase onward the menubar app and the CLI write to *different physical roots* (app → its sandbox container; CLI → user-domain `Application Support`). Code is unchanged because `FileManager.applicationSupportDirectory` resolves both. The CLI ships a **`tatlin clean`** subcommand to wipe its own sessions / models / both, since the user can't reach the CLI store from Finder without going through `~/Library/Application Support/dev.kalambet.tatlin/`.

### Phase 1B — Model infrastructure + Eval harness  *(parallel; de-risks ADR-2/3/6)*
**Status (2026-06-18): infrastructure code-complete & building.** `ModelManifest`, `ModelStore`, `ModelDownloader` (SHA-256), `CoreMLCompiler`, `ModelHost` (sequential residency), WER/DER/report harness, and `models`/`eval` CLI subcommands landed; 61 unit tests green. **Remaining:** (a) the concrete MLX/FluidAudio engine conformances in the `TatlinML` target (need on-device weights — next step); (b) fill exact HF file URLs + sha256 in the manifest; (c) run the actual ASR bake-off + DER on real audio (M1B.3/M1B.4 acceptance).
**Goal:** prove model download/run plumbing and settle the ASR bake-off on real data.
- M1B.1 `ModelManifest` (ids, URLs, SHA-256, size, license) + `ModelHost` actor: background `URLSession` download, checksum, CoreML compile + `.mlmodelc` cache, sequential load/unload, `MLX.GPU.set(cacheLimit:)`.
- M1B.2 `ParakeetEngine` + `VoxtralEngine` (+ optional `WhisperKitEngine`) behind `ASREngine`.
- M1B.3 `TatlinEval`: **ASR bake-off** — WER (RU/DE/EN + code-switch subset) + timestamp sanity + latency/memory, Parakeet vs Voxtral-4B-fp16 on a small labeled set (~10–20 clips incl. real meeting audio). Decide whether Voxtral's timestamp work is ever worth it.
- M1B.4 `DiarizerEngine` over FluidAudio + **DER/JER harness** (community-1) on representative multi-party clips; record overlap-region accuracy.
- M1B.5 `LLMEngine` over MLXLLM loads Qwen3-30B-A3B-8bit; smoke-test structured Markdown + tokenizer-based length budgeting.
- **Acceptance:** all four models download→verify→compile→run→unload within memory budget on the M5; bake-off + DER numbers written to `eval/results.md`; ASR primary confirmed (or switched) with evidence.

### Phase 2 — Batch pipeline  *(CLI-driven, brief §10 Phase 2)*
**Status (2026-06-18): pipeline logic code-complete & verified; ML engines written, pending on-device build.** `WordAligner`, `SpeakerID` (`EnrollmentStore`+`SpeakerResolver`), `TranscriptChunker`/`SummaryPrompt`/`NotesParser`, `MarkdownComposer`, `BatchPipeline` (stages 2–7, resume), `StubEngines`, and `tatlin run` landed; 88 unit tests green; verified end-to-end producing a well-formed Obsidian note with stub engines. Concrete `TatlinML` engines (Parakeet/Voxtral/WhisperKit/FluidAudio/Qwen) **enabled and compiling on the M5** against the real APIs (all `// VERIFY` gaps closed; resolved deps pinned in `Package.resolved` — FluidAudio 0.15.4, mlx-swift-lm 2.31.3); `tatlin run` wires the real engines by default (`--stub` for dry runs). Build with `swift build --product tatlin`. **Remaining (needs weights/credentials):** download model weights (`tatlin models download …`; Qwen ~32 GB, community-1 gated CC-BY), then run on real audio — the ASR bake-off + DER eval + a real summarization pass (Stage 5 of BRINGUP). Word-level ASR timing is sentence-granular today (public mlx-audio API limitation).
**Goal:** saved audio → final Markdown, no app/UX.
- M2.1 `Audio` resampler (48k→16k mono, in-memory).
- M2.2 Stage 2 wire-up: recording → `transcript.json` (words+timestamps).
- M2.3 Stage 3: `diarization.json` (turns+embeddings) + `OwnerVAD` on mic channel.
- M2.4 Stage 4 `Alignment`: word-level max-overlap + interval tree; owner-precedence merge; `overlap=true` flags → `aligned.json`.
- M2.5 Stage 5 `SpeakerID`: **roster prime from the calendar attendee list (ADR-13)** → owner anchor (mic cluster) → enrolled-embedding match (persistent speaker DB) → unknowns stay `Speaker N`. The roster is passed to Stage 6 so LLM relabel *matches against known attendees* instead of free-guessing.
- M2.6 Stage 6 `Summarization`: prompt templates (system skeleton + RU/DE/EN one-shot exemplar), `<think>`-strip is N/A (instruct), MD validator + one repair pass, `speaker_name_map` with evidence/confidence; single-pass ≤~28k else map-reduce on turn boundaries; prompt-injection delimiting; **output language per Settings** (default *Match meeting* → detect dominant transcript language and pin the notes to it; else honor the override).
- M2.7 Stage 7 `Output`: `MarkdownComposer` (YAML front-matter — incl. calendar title/attendees/event time when present — + TL;DR/decisions/actions/open-questions/per-speaker + full diarized transcript) → vault path; filename from event title (sanitized) else timestamped default.
- M2.8 `BatchPipeline` orchestrator + `tatlin run <session>` with `--from-stage` resume; structured progress events.
- M2.9 **Dual-channel ASR + timeline merge** *(code-complete 2026-06-20, pending real-Zoom acceptance).*
  - `BatchPipeline.AudioSource.merged` is the **new default**. `.system` and `.mic` stay as advanced/legacy modes.
  - Stage 2: when `.merged`, both channels are ASR'd inside a single `ModelHost.withModel` block (load once, transcribe twice, unload), producing `transcript-system.json` + `transcript-mic.json`. Single-channel modes keep writing `transcript.json` unchanged.
  - Stage 3: diarization runs on the system channel only; `ownerVAD` still runs as a fallback owner-anchor signal.
  - Stage 4: new `WordAligner.alignDual(micTranscript:, systemTranscript:, systemDiarization:, ownerLabel:)` tags every mic word as owner, runs system words through the existing single-channel `align(...)`, then interleaves by `word.start` and flags cross-channel overlap on both sides (caller talking over a remote participant). Mic-first stable tie-break on equal starts.
  - Speaker-ID falls out naturally: mic words = owner; system words follow the diarizer + LLM relabel.
  - Settings picker semantics shipped: **Remote meeting (mic + system, merged)** *(default)* / **In-person (mic only)** / **System only** *(advanced)*.
  - 5 alignDual unit tests + 1 `.merged` end-to-end pipeline test (88 → 94 in TatlinKit). All green.
  - **Acceptance still owed:** a real Zoom/Meet recording producing notes with both owner words and remote participants on one timeline, correctly speaker-attributed.
- **Acceptance:** `tatlin run` on a real 1–2 h recording yields correct, well-formed Obsidian notes; each stage independently re-runnable; peak memory under budget; golden-set eval (research Q6 eval debt) scored. **M2.9 acceptance:** a remote-meeting capture (real Zoom/Meet call) produces a transcript with both the owner's and remote participants' words on a single merged timeline, correctly speaker-attributed.

### Phase 3 — App glue + UX
**Goal:** the unobtrusive menubar product.
- M3.1 `MenuBarExtra` shell, `LSUIElement`, two-state icon (idle vs capturing+red dot), start/stop toggle, status.
- M3.1b **Event picker window** (ADR-13): shown on Start only when ≥2 candidate events; lists title/time/attendee-count + "None / custom name"; non-blocking to capture (metadata attaches on pick).
- M3.2 First-run onboarding: sequential permission requests (Microphone → Screen & System Audio → **Calendar, read-only, optional/skippable**) + relaunch handling + Settings deep-links + warning badge when missing; model-download progress UI w/ minimal-mode (small ASR first). Calendar denial is non-blocking — app falls back to timestamped names.
- M3.3 `SMAppService.mainApp` login-item toggle (default OFF; status re-check on activation).
- M3.4 Auto-trigger `BatchPipeline` on capture stop; background processing with progress + completion notification; "Resume" list for interrupted sessions.
- M3.5 Speaker-naming UI: confirm/correct inferred names → write back to enrollment store (self-improving loop).
- M3.6 **Settings page:** vault folder (Obsidian/Synology synced path) — stored as a **security-scoped bookmark** (ADR-9a sandbox is ON, so a raw path string can't survive relaunch); **meeting skip-list** (titles to ignore — defaults OOO/Focus, user-editable, drives ADR-13 filter); **output language** (default *Match meeting* = auto-detect dominant; overrides English/German/Russian); **Spoken language** picker — drives `ASROptions.languageHint` so the user can constrain ASR to the language(s) they actually speak instead of letting Parakeet drift to misdetections (e.g., classifying Russian as Czech). v1: single-pick (`Auto` / `English` / `Russian` / `German` / …). Whether single-pick is enough or we need a multi-pick allowlist + per-segment best-of-two pass is decided by **M1B.3** WER on a multi-language clip set — the picker exists either way, but the underlying engine choice (Parakeet soft-prior vs WhisperKit hard-lock vs dual-pass) is bake-off-driven; **Models section** — table of `ModelManifest` entries with installed/missing state + size + license + per-row Download/Delete buttons backed by `ModelDownloader` (progress fraction surfaces in the row, not a modal); model selection/quant; output template.
- M3.7 **Icons** (research Q8): Icon Composer `.icon` (near-black Tatlin Tower) + legacy AppIcon set; menubar PDF templates for both states.
- M3.8 Developer-ID signing + notarization (ADR-9); attribution/licenses screen (pyannote/WeSpeaker/FluidInference CC-BY; model cards).
- M3.9 **Per-series meeting memory** (proposed 2026-06-23; design from the #3 feedback thread). Recurring meetings gain continuity — the summariser is primed with the previous meeting plus a rolling series state, so action items carry forward and speaker names stay consistent across instances.
  - **Series identity (ADR-14).** Group sessions by a stable `seriesKey`: the calendar recurring-event identity when the event recurs — captured as `EventSnapshot.seriesID` from `EKEvent.calendarItemExternalIdentifier` (stable across instances) at Start (ADR-13) — else the normalized title. One-off / non-calendar meetings fall back to title-grouping.
  - **Vault layout.** A series' notes live in their own subfolder, `<vault>/<sanitized-series-name>/<note>.md`, alongside a maintained `state.md` (the running series summary). Pre-existing flat notes are left untouched; only new notes route into folders.
  - **Context into Stage 6.** Load the previous meeting's *full* notes + the current `state.md` and inject them into the summariser system prompt as continuity context ("data, not instructions; do not re-summarise; carry forward still-open action items; reuse established speaker names"). For long (map-reduce) transcripts, inject at the **reduce** step only to stay within the token budget.
  - **Stage 6b — `state.md` update.** After the meeting's notes are written, a second LLM pass folds the new meeting into `state.md` (ongoing themes, cross-meeting open action items, decisions, people/roles, current status). The first meeting in a series seeds `state.md` from its own notes. Update failure is non-fatal (keep the prior state).
  - **Touch points.** `Calendar/EventSnapshot.swift` (+`seriesID`), `Calendar/CalendarService.swift` (capture external id + `hasRecurrenceRules`), `Summarization/SummaryPrompt.swift` (series-context block + `updateState` prompt), `Pipeline/BatchPipeline.swift` (load context pre-summary; run state-update + series-folder write post-summary), `Output/MarkdownComposer.swift` (series subfolder + `state.md`), `Session/SessionStore.swift` (list sessions by series).
  - **Acceptance:** a second instance of a recurring 1:1 produces notes that continue the first (carried-forward action items, consistent names), and `state.md` reflects both meetings; ad-hoc/no-calendar meetings still summarise standalone.
- **Acceptance:** clean first-run on a fresh account; click-to-capture; auto-produces notes on stop; survives logout/login as a login item; notarized build runs without Gatekeeper friction.

### Phase 4 — v2+  (deferred)
Calendar-triggered / VAD auto-segmentation; richer speaker enrollment UI; output templates; summary-quality eval suite; global-CATap fallback capture path; Voxtral timestamp extraction *if* the bake-off justified it.

---

## Part D — Testing & Quality
- **Unit:** Swift Testing for SessionStore, resampler, alignment math (interval tree, overlap), Markdown validator, manifest/checksum.
- **Eval harness (`TatlinEval`):** ASR WER + diarization DER + summary golden-set; re-runnable, results checked into `eval/`. This is the real quality signal (research risks #3, Q6 eval debt).
- **Golden-summary generation (dev-only, Part F #5):** `tools/eval-golden/` — a throwaway Python/Ollama (or API) script that produces reference summaries for hand-curated transcripts, scored against Qwen3's output (section completeness, action-item/owner recall, decision recall, hallucination, language fidelity). **Never bundled or shipped** (C1: dev spike only); lives outside the SwiftPM build.
- **Integration:** `tatlin run` against a committed fixture session (short, license-clean audio).
- **Manual:** the Phase-3 acceptance scenarios on a fresh macOS account.

## Part E — Risks → mitigations (carried from research)
| Risk | Mitigation | Phase |
|---|---|---|
| Pre-1.0 Swift ML tooling churn (mlx-audio-swift 0.1.x, FluidAudio 0.14/0.15) | Pin exact versions; protocol seams (`ASREngine`/`DiarizerEngine`) isolate swaps; verify symbols vs installed revs | 1B |
| Model quality unknowns (WER/DER vs marketing) | Eval harness on real audio before committing | 1B/2 |
| 64 GB ceiling | `ModelHost` strict sequential residency; never co-reside | 1B |
| SCStream long-session instability | Watchdog + flush + restart | 1 |
| Gated CC-BY models | Vendor weights, in-app license acceptance + attribution | 1B/3 |
| Permission UX friction (monthly re-auth, "audio needs Screen Recording", big first download) | Explicit onboarding copy; minimal-mode download | 3 |
| LLM speaker hallucination | Evidence-gated, confidence-flagged, human-correctable | 2 |

## Part F — Resolved decisions / remaining build-time items
1. ✅ **Distribution (ADR-9)** — direct, Developer-ID-notarized `.app` via GitHub Releases (later Homebrew cask), sandbox OFF.
2. ✅ **Vault + skip-list** — configurable on a **Settings page** (M3.6): vault path + user-editable meeting skip-list (defaults OOO/Focus). *Title (ADR-13): event title when present, else `Tatlin YYYY-MM-DD HHmm`.*
3. ✅ **Output language** — Settings option, default **Match meeting** (auto-detect dominant transcript language), with English/German/Russian overrides (M3.6/M2.6).
4. **Enrollment threshold** — empirically set FluidAudio similarity threshold (unpublished) in Phase 1B. *(build-time)*
5. ✅ **Dev golden-summary spike** — yes: a **throwaway, dev-only** Python/Ollama tool (`tools/eval-golden/`, NOT shipped, allowed by C1) to generate reference summaries for the `TatlinEval` golden set. See Part D.
6. ✅ **Calendar matching at Start** — non-meeting filter (all-day/free/unavailable/skip-list) then 0→default, 1→silent, ≥2→**picker window** (ADR-13).

---
### Immediate next step on approval
Kick off **Phase 1 + Phase 1B in parallel**: scaffold the SwiftPM workspace + capture spike, and stand up `ModelHost` + the ASR bake-off harness.
