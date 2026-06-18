# Tatlin — Project Brief

> A local-first, privacy-preserving, **background**, **Swift-native** meeting note-taker for macOS. It quietly records a conversation, then produces a **speaker-attributed transcript and structured notes** entirely on-device, using **Mistral models** for transcription and summarization. Named after Vladimir Tatlin's *Monument to the Third International* — a broadcasting tower that was never built — and in deliberate homage to the Constructivist "form follows function" ethos.

---

## How to use this document

This is the seed context for a Claude Code session. The work splits into three phases:

1. **Research** — resolve the open questions in §9 against the *current* state of the tooling. Versions, APIs, and macOS behavior move fast; verify everything dated and don't trust this doc's specifics blindly (assembled mid-2026).
2. **Plan** — produce an architecture decision record and a phased implementation plan (see §10–11).
3. **Build** — implement v1 in Swift, then iterate.

Do not start coding before completing the research phase and getting sign-off on the architecture decision (diarization backend + Voxtral model choice, §5.2).

---

## 1. Vision

A tool the owner can leave running in the background during any meeting — remote call or in-person — so they can fully concentrate on the conversation rather than note-taking. When the session ends, Tatlin produces a clean Markdown artifact: a diarized (speaker-labeled) transcript plus a structured summary with decisions and action items. Nothing leaves the machine.

The central simplifying insight: **the owner only wants the *final* notes, not a live view.** Therefore **no part of the pipeline needs to be real-time.** Everything downstream of audio capture is batch post-processing run after the session ends. This eliminates streaming ASR, live diarization, and real-time stream alignment — the hardest parts of this problem class — and lets the design use higher-accuracy offline models.

## 2. Goals & Non-Goals

**Goals**
- Fully local / on-device processing. No third-party cloud services in the default path.
- **Swift-native**, self-contained app. No Python runtime, no local server dependency in the shipped product.
- **Mistral models** for transcription and summarization (see §3 hard constraint and its one exception).
- Background, unobtrusive operation. Minimal interaction; the owner should be able to forget it's running.
- High-quality **speaker separation in the final output** (who said what).
- Structured Markdown notes (summary, decisions, action items, per-speaker points) plus the full diarized transcript.
- Multilingual: must handle **Russian, German, and English** robustly, including code-switching within a meeting.
- Self-built and free of per-seat SaaS fees.

**Non-Goals (v1)**
- Live, on-screen transcription or live speaker labels.
- Real-time latency targets of any kind.
- Cross-platform support (macOS only; Apple Silicon only).
- Multi-user / team features, sharing, or a hosted backend.
- Calendar-driven automation (deferred to v2; see §10).

## 3. Hard Constraints

- **C1 — Swift-native.** The app is a native macOS Swift/SwiftUI application. All inference runs on-device via the Apple-Silicon ML stack (MLX / CoreML / ANE). No bundled Python interpreter, no sidecar server process in the shipped build. (A Python or Ollama path is acceptable *only* as a throwaway development spike, never in the product.)
- **C2 — Mistral models for ASR + summarization.** Transcription uses **Voxtral** (open weights, run via the Swift MLX stack). Summarization uses a **Mistral** text LLM (e.g. Mistral Small, run in-process via mlx-swift).
  - **C2 exception — diarization.** Mistral ships **no open, locally-runnable speaker-diarization model**; its only diarizing model (Voxtral Mini Transcribe V2) is cloud/API-only and thus disqualified by the local-only requirement. Diarization therefore uses non-Mistral acoustic models (pyannote / Sortformer / WeSpeaker), delivered **natively** via CoreML so C1 still holds. This is the single, unavoidable deviation from C2 and is considered acceptable because diarization is acoustic speaker-clustering, a different model category from ASR/LLM.

## 4. Target User & Environment

Single technical user (the author). Assume a senior-engineer audience: terse, precise, no hand-holding. Comfortable with Swift, SwiftUI, the Apple ML stack, Hugging Face tooling, launchd.

- **Machine:** MacBook M5 Pro, 64 GB unified memory. Both dev and runtime host. Ample headroom to run a Voxtral ASR model + a CoreML diarizer + a ~24B Mistral LLM concurrently.
- **OS:** current macOS (verify exact version at build time; it affects the audio-capture API choice — see §9).
- **Existing stack to integrate with:** **Obsidian** as the notes destination (output must be Obsidian-friendly Markdown);

## 5. Proposed Architecture

A four-stage pipeline. Stage 1 runs live (capture only); stages 2–4 run as a batch job triggered when the session ends. All stages are Swift, on-device.

### 5.1 Stage 1 — Capture (the only macOS-specific, real-time part)
- Capture system output audio + mic, ideally as **separate channels**, into a single recording (FLAC or WAV).
- On current macOS, system-audio capture should **not** require a virtual device like BlackHole — use **ScreenCaptureKit** (audio-only `SCStream`) or a **Core Audio process tap** (`AudioHardwareCreateProcessTap` + aggregate device). Mic via **AVAudioEngine**. *Confirm the best current API for the target macOS version in research (§9).*
- **Separate-mic-channel optimization:** recording the owner's mic on its own channel makes "owner vs. everyone else" largely solved before diarization runs, and gives a reliable identity anchor for the owner. Strongly consider.
- Run the app as a **launchd LaunchAgent** (headless, starts at login) with a minimal **SwiftUI menubar** control for start/stop + status.
- Make sure that by default the app is not capturing anything (i.e., no audio input from the mic or system output) and only starts capturing when the user click the Menu bar icon.
- Menu bar icon should have two states: one for "capturing" and one for "not capturing".
- When the user clicks the Menu bar icon, the app should toggle between these states: if not capturing, start capturing; if capturing, stop capturing.

### 5.2 Stages 2–4 — Batch processing

**Stage 2 — Transcription (Mistral / Voxtral).**
- Use **open-weights Voxtral** via the Swift MLX stack (mlx-swift / mlx-audio-swift). Candidate models: Voxtral Mini 4B Realtime-2602 used in batch mode, or the original Voxtral Mini. **Research must pick the open Voxtral variant with the best batch multilingual (RU/DE/EN) WER** (§9).
- Note: open Voxtral is **transcription-only** — it does not diarize.

**Stage 3 — Diarization + alignment (C2 exception; native CoreML).**
- Use **FluidAudio** (Swift SPM package; CoreML, ANE-optimized) for speaker diarization. It exposes multiple backends — **Sortformer** (end-to-end on ANE), **LS-EEND**, and a classic **pyannote 3.1 + WeSpeaker** pipeline, plus **pyannote community-1** — and ships converted CoreML models. `speech-swift` (MLX + CoreML) is a secondary candidate if FluidAudio falls short.
- Prefer **offline, overlap-aware** diarization (the batch design permits it; overlap-awareness is the single biggest accuracy lever on multi-party meeting audio). **Research must choose the backend** (Sortformer vs pyannote-pipeline vs community-1) on RU/DE/EN multi-party audio with cross-talk (§9).
- **Alignment:** own Swift code — assign each Voxtral transcript segment to the diarizer speaker turn it overlaps most (word/segment timestamps from Voxtral × speaker turns from FluidAudio).
- **Speaker identity:** diarizer emits anonymous `SPEAKER_xx`. Map to real names via (a) the separate-mic-channel anchor for the owner, (b) enrolled reference embeddings (FluidAudio exposes speaker embeddings), or (c) LLM relabeling from context in Stage 4. Decide the approach.

**Stage 4 — Summarization (Mistral).**
- Run a **Mistral** text LLM **in-process via mlx-swift** (MLXLLM). Candidate: **Mistral Small** (latest 3.x, MLX ~4-bit) — comfortably within 64 GB and a strong summarizer; Magistral Small if more structured reasoning is wanted. Verify the current best Mistral model + MLX build at build time.
- Prompt for structured output: TL;DR, key decisions, action items (with owner if inferable), open questions, per-speaker highlights.
- **Long meetings:** chunk the transcript and map-reduce, or raise context deliberately; do not feed multi-hour transcripts in one pass.

**Stage 5 — Output.**
- Write Markdown (YAML front-matter + structured notes + full diarized transcript) to a configured folder synced by the Synology and indexed by Obsidian. Stable, sortable filenames (timestamp + optional title).

## 6. Key Decisions Already Made (with rationale)

- **Batch, not real-time** — because only final notes are needed. Load-bearing; preserve it.
- **Local-only** — privacy is the core value; cloud is out of the default path.
- **Swift-native, MLX/CoreML, no Python** — C1; now fully viable end-to-end (capture, ASR, diarization, LLM).
- **Mistral for ASR + summary; CoreML pyannote/Sortformer for diarization** — C2 and its one documented exception.
- **Offline overlap-aware diarization** — accuracy over latency, which the batch design permits.
- **Markdown output to a synced folder** — fits the existing Obsidian + Synology workflow; no new storage layer.
- **launchd LaunchAgent + SwiftUI menubar** — unobtrusive background operation.

## 7. Technology Stack (verify currency in research)

- **App / UI:** Swift, SwiftUI, AppKit menubar; launchd LaunchAgent.
- **Capture:** ScreenCaptureKit (audio-only) and/or Core Audio process taps; AVAudioEngine for mic.
- **ASR:** open-weights Voxtral via **mlx-swift / mlx-audio-swift**.
- **Diarization:** **FluidAudio** (CoreML; Sortformer / pyannote / WeSpeaker), with `speech-swift` as backup. (`sherpa-onnx` has Swift bindings but is CPU-only / no ANE — note but deprioritize.)
- **LLM:** **Mistral Small** (or Magistral Small) via **mlx-swift (MLXLLM)**, in-process.
- **Glue:** Swift (structured concurrency / async-await for orchestration).

## 8. Known Constraints & Gotchas

- **macOS permissions:** Screen Recording + Microphone, granted once; the LaunchAgent inherits them. Plan the first-run permission flow.
- **Audio API churn:** the right system-audio capture API depends on the macOS version — verify before building Stage 1.
- **Model licensing:** Voxtral open weights are Apache 2.0; FluidAudio SDK is Apache 2.0 but its converted pyannote models are CC-BY-4.0 — check attribution/compliance for the diarization models.
- **Speaker naming** is unsolved out of the box; decide the strategy (§5.2).
- **Session boundaries:** v1 = manual menubar toggle. v2 = calendar-triggered or VAD-based auto-segmentation.
- **Crash safety:** persist raw audio immediately; make stages 2–4 re-runnable against the saved file.
- **Memory:** Voxtral + CoreML diarizer + ~24B Mistral LLM resident together — confirm peak footprint stays comfortably under 64 GB, or load/unload stages sequentially.

## 9. Open Research Questions (resolve FIRST)

1. **Audio capture:** On the owner's current macOS version, the most reliable, low-friction way to capture system audio + mic to a single (ideally dual-channel) file *without* a virtual device — ScreenCaptureKit audio-only vs Core Audio process taps; current sample code; channel-separation feasibility.
2. **Voxtral in Swift:** Maturity of mlx-swift / mlx-audio-swift for **batch file transcription** with open Voxtral on Apple Silicon. Which exact model + quantization gives the best RU/DE/EN (incl. code-switching) WER? Confirm word/segment timestamps are available for alignment.
3. **Diarization backend:** Within FluidAudio, compare **Sortformer vs pyannote-3.1-pipeline vs community-1** for offline, overlap-aware diarization on ~1–2h multi-party meeting recordings with cross-talk. Accuracy (DER) and ANE runtime. Is FluidAudio sufficient, or is `speech-swift` better?
4. **Alignment:** Best approach to align Voxtral segment timestamps with FluidAudio speaker turns; handling overlapped speech.
5. **Speaker identity:** Turning `SPEAKER_xx` into real names given the separate-mic anchor — embedding enrollment (FluidAudio) vs LLM relabeling.
6. **Mistral LLM in Swift:** Current best Mistral model + MLX build for structured summarization at 64 GB via mlx-swift; long-transcript strategy (map-reduce vs large context); in-process feasibility alongside the ASR/diarizer.
7. **Packaging:** launchd LaunchAgent + menubar lifecycle; bundling CoreML/MLX models; first-run permissions and model download UX.
8. **Icons:** Design and prototype custom icons for the menubar icon (capturing/not capturing). I want for an app icon to have a black background and light grey foreground, with a Tatlin Tower in the center. For the menubar icon, I want for it to be able to accomodate light and dark mode and also represent Tatlin Tower but with status (capturing/not capturing).

## 10. Suggested Phased Plan

- **Phase 0 — Research (§9).** Findings doc + the diarization-backend and Voxtral-model decisions.
- **Phase 1 — Capture spike (riskiest unknown).** Headless Swift recorder writing a clean dual-channel file; verify permissions and audio quality end-to-end.
- **Phase 2 — Batch pipeline.** Recorded file → Voxtral transcript → FluidAudio diarization → alignment → Mistral summary → Markdown. Driven from a CLI/test harness against a saved file.
- **Phase 3 — Glue + UX.** launchd LaunchAgent + SwiftUI menubar; auto-trigger processing on session stop; speaker-naming strategy.
- **Phase 4 (v2+).** Calendar-triggered or VAD auto-segmentation; speaker enrollment; output templates; summary-quality evals.

## 11. Deliverables Expected From the Claude Code Session

1. A research findings document answering §9, with current versions and links.
2. An architecture decision record: diarization backend, Voxtral model, capture API, model-loading/memory strategy.
3. A phased implementation plan with concrete milestones.
4. Then: the implementation in Swift, starting with the Phase 1 capture spike.

---

*Working name: **Tatlin**. ("TATLIN" is also an enterprise storage line from YADRO — different domain, scale, and audience; not a concern for a personal tool, but it dominates search results, so don't expect the name to be discoverable.)*
