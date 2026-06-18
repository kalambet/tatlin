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
- **ADR-9 — Distribution: Developer-ID-signed + notarized `.app`, shipped via GitHub Releases (later a Homebrew cask), NOT Mac App Store.** ✅ confirmed. **Sandbox OFF** — simplifies SCStream, EventKit, and the Application Support model store; acceptable for a self-distributed personal tool. Rationale: ~15–25 GB model downloads break the App Store size/ODR model; screen-recording + system-audio is review friction. Build a notarized `.app` in a `.dmg`/zip for the Releases page; add a `Casks/tatlin.rb` Homebrew cask once releases stabilize.
- **ADR-10 — Two front doors over one core library.** A SwiftPM package (`TatlinKit`) holds all pipeline logic; a **CLI harness** (`tatlin-cli`) and the **menubar app** (`Tatlin`) are thin shells over it. The CLI lets Phase 2 run end-to-end against saved audio long before the app/UX exists (brief §10 Phase 2).
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
Tatlin/                                  (SwiftPM workspace, no git yet → git init in Phase 1)
  Package.swift
  Sources/
    TatlinKit/                           library — all pipeline logic, platform-agnostic where possible
      Session/        SessionStore, artifact codables, resume logic
      Calendar/       CalendarService (EventKit, read-only), current-event snapshot, roster
      Capture/        SCStreamRecorder, AudioWriter, dual-channel WAV
      Audio/          AVAudioConverter resampling (48k→16k mono)
      Transcription/  ASREngine protocol, ParakeetEngine, (VoxtralEngine, WhisperKitEngine)
      Diarization/    DiarizerEngine wrapper over FluidAudio, OwnerVAD
      Alignment/      word×turn assignment, interval tree, overlap flagging
      SpeakerID/      anchor resolver, embedding enrollment store
      Summarization/  LLMEngine over MLXLLM, prompt templates, MD validator/repair
      Output/         MarkdownComposer, front-matter, vault writer
      Models/         ModelHost actor, ModelManifest, downloader, SHA-256, CoreML compile
      Pipeline/       BatchPipeline orchestrator (stages 2–7), Progress events
    Tatlin/                              app — SwiftUI MenuBarExtra shell
      App, MenuBarScene, Onboarding/Permissions, SettingsView, SpeakerNamingView
    tatlin-cli/                          executable — record / run-pipeline / eval subcommands
  Tests/
    TatlinKitTests/
    TatlinEval/                          ASR WER bake-off + diarization DER harness
  Models/                               (gitignored) local model cache for dev; manifest checked in
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
- M1.1 `git init`; SwiftPM scaffold; `tatlin-cli record` subcommand.
- M1.2 `SCStreamRecorder`: `capturesAudio + captureMicrophone`, separate `.audio`/`.microphone` outputs → two `AudioWriter`s (independent timestamp baselines) → `raw-system.wav` + `raw-mic.wav` (48 kHz/32-bit float mono).
- M1.3 `SessionStore`: create `~/…/Tatlin/sessions/<ISO8601>/` + `session.json` on record-start; flush-on-write.
- M1.4 Permission flow probe: mic (`AVCaptureDevice`) + screen/system-audio (`SCShareableContent`); handle relaunch-after-grant.
- M1.5 Stability: stalled-callback watchdog → restart stream + flush (research Q1 risk).
- M1.6 `CalendarService` (ADR-13): on Start, read-only `EventKit` snapshot of events overlapping now → apply non-meeting filter (all-day / `.free`/`.unavailable` availability / OOO+Focus title heuristics) → title, attendees (name+email), notes, start/end → `session.json`. Resolution: 0 → timestamped default (`Tatlin YYYY-MM-DD HHmm`); 1 → silent; ≥2 → **picker window** (title/time/attendee-count + "None / custom name"). Degrades silently if calendar permission absent. (Picker UI itself lands in Phase 3; CLI/headless path uses 0/1-candidate logic + a `--event-id` flag for ≥2.)
- **Acceptance:** record a real 30-min Zoom/Meet/in-person session; both WAVs valid & independently playable; owner clearly isolated on mic channel; survives app kill mid-session (partial WAVs still valid); AirPods-mic path tested; starting during a scheduled meeting captures the right event metadata, and starting with no meeting yields a clean default name.

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
**Status (2026-06-18): pipeline logic code-complete & verified; ML engines written, pending on-device build.** `WordAligner`, `SpeakerID` (`EnrollmentStore`+`SpeakerResolver`), `TranscriptChunker`/`SummaryPrompt`/`NotesParser`, `MarkdownComposer`, `BatchPipeline` (stages 2–7, resume), `StubEngines`, and `tatlin run` landed; 88 unit tests green; verified end-to-end producing a well-formed Obsidian note with stub engines. Concrete `TatlinML` engines (Parakeet/Voxtral/WhisperKit/FluidAudio/Qwen) written against pinned library APIs in a separate, not-yet-compiled target. **Remaining:** enable `TatlinML` on the M5 (uncomment Package.swift per `Sources/TatlinML/README.md`), close the ~10 `// VERIFY` API gaps on first compile, download weights, then run the real ASR bake-off + DER eval and a real summarization pass.
**Goal:** saved audio → final Markdown, no app/UX.
- M2.1 `Audio` resampler (48k→16k mono, in-memory).
- M2.2 Stage 2 wire-up: recording → `transcript.json` (words+timestamps).
- M2.3 Stage 3: `diarization.json` (turns+embeddings) + `OwnerVAD` on mic channel.
- M2.4 Stage 4 `Alignment`: word-level max-overlap + interval tree; owner-precedence merge; `overlap=true` flags → `aligned.json`.
- M2.5 Stage 5 `SpeakerID`: **roster prime from the calendar attendee list (ADR-13)** → owner anchor (mic cluster) → enrolled-embedding match (persistent speaker DB) → unknowns stay `Speaker N`. The roster is passed to Stage 6 so LLM relabel *matches against known attendees* instead of free-guessing.
- M2.6 Stage 6 `Summarization`: prompt templates (system skeleton + RU/DE/EN one-shot exemplar), `<think>`-strip is N/A (instruct), MD validator + one repair pass, `speaker_name_map` with evidence/confidence; single-pass ≤~28k else map-reduce on turn boundaries; prompt-injection delimiting; **output language per Settings** (default *Match meeting* → detect dominant transcript language and pin the notes to it; else honor the override).
- M2.7 Stage 7 `Output`: `MarkdownComposer` (YAML front-matter — incl. calendar title/attendees/event time when present — + TL;DR/decisions/actions/open-questions/per-speaker + full diarized transcript) → vault path; filename from event title (sanitized) else timestamped default.
- M2.8 `BatchPipeline` orchestrator + `tatlin-cli run <session>` with `--from-stage` resume; structured progress events.
- **Acceptance:** `tatlin-cli run` on a real 1–2 h recording yields correct, well-formed Obsidian notes; each stage independently re-runnable; peak memory under budget; golden-set eval (research Q6 eval debt) scored.

### Phase 3 — App glue + UX
**Goal:** the unobtrusive menubar product.
- M3.1 `MenuBarExtra` shell, `LSUIElement`, two-state icon (idle vs capturing+red dot), start/stop toggle, status.
- M3.1b **Event picker window** (ADR-13): shown on Start only when ≥2 candidate events; lists title/time/attendee-count + "None / custom name"; non-blocking to capture (metadata attaches on pick).
- M3.2 First-run onboarding: sequential permission requests (Microphone → Screen & System Audio → **Calendar, read-only, optional/skippable**) + relaunch handling + Settings deep-links + warning badge when missing; model-download progress UI w/ minimal-mode (small ASR first). Calendar denial is non-blocking — app falls back to timestamped names.
- M3.3 `SMAppService.mainApp` login-item toggle (default OFF; status re-check on activation).
- M3.4 Auto-trigger `BatchPipeline` on capture stop; background processing with progress + completion notification; "Resume" list for interrupted sessions.
- M3.5 Speaker-naming UI: confirm/correct inferred names → write back to enrollment store (self-improving loop).
- M3.6 **Settings page:** vault folder (Obsidian/Synology synced path); **meeting skip-list** (titles to ignore — defaults OOO/Focus, user-editable, drives ADR-13 filter); **output language** (default *Match meeting* = auto-detect dominant; overrides English/German/Russian); model selection/quant; output template.
- M3.7 **Icons** (research Q8): Icon Composer `.icon` (near-black Tatlin Tower) + legacy AppIcon set; menubar PDF templates for both states.
- M3.8 Developer-ID signing + notarization (ADR-9); attribution/licenses screen (pyannote/WeSpeaker/FluidInference CC-BY; model cards).
- **Acceptance:** clean first-run on a fresh account; click-to-capture; auto-produces notes on stop; survives logout/login as a login item; notarized build runs without Gatekeeper friction.

### Phase 4 — v2+  (deferred)
Calendar-triggered / VAD auto-segmentation; richer speaker enrollment UI; output templates; summary-quality eval suite; global-CATap fallback capture path; Voxtral timestamp extraction *if* the bake-off justified it.

---

## Part D — Testing & Quality
- **Unit:** Swift Testing for SessionStore, resampler, alignment math (interval tree, overlap), Markdown validator, manifest/checksum.
- **Eval harness (`TatlinEval`):** ASR WER + diarization DER + summary golden-set; re-runnable, results checked into `eval/`. This is the real quality signal (research risks #3, Q6 eval debt).
- **Golden-summary generation (dev-only, Part F #5):** `tools/eval-golden/` — a throwaway Python/Ollama (or API) script that produces reference summaries for hand-curated transcripts, scored against Qwen3's output (section completeness, action-item/owner recall, decision recall, hallucination, language fidelity). **Never bundled or shipped** (C1: dev spike only); lives outside the SwiftPM build.
- **Integration:** `tatlin-cli run` against a committed fixture session (short, license-clean audio).
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
