# Tatlin — On-Device Bring-Up Guide

Everything built so far (`scaffold` → Phase 2) compiles and is unit-tested in CI with **stub
engines**. This guide is the ordered checklist for taking it onto the **M5 Pro (macOS 26)** and
getting a real meeting → real notes. Do the steps in order; each is independently testable.

> Quick status (updated 2026-06-18): `TatlinML` is **enabled and compiling** against the real
> MLX/FluidAudio APIs — all the original `// VERIFY` gaps are closed (Stage 2 done). `tatlin run`
> uses the real engines by default. What remains is on hardware: **download weights** (Stage 3),
> **run on real audio** (Stage 4), and **the eval pass** (Stage 5) — plus Stage 1 live capture.
>
> ⚠️ **Build with `swift build --product tatlin`**, not bare `swift build`: FluidAudio's *own*
> `FluidAudioCLI` benchmark target hits a compiler type-check-timeout (a bug in their code, in a
> target we don't use). `swift run tatlin …` and `swift test` are unaffected.
>
> ⚠️ **Dependency resolution needs HTTPS.** Your global git rewrites GitHub→SSH and the 1Password
> SSH agent was refusing to sign, so `swift package resolve` was run with a throwaway
> `GIT_CONFIG_GLOBAL` (empty) to force plain HTTPS. If you re-resolve and it fails on SSH, either
> unlock 1Password or run: `GIT_CONFIG_GLOBAL=/tmp/empty swift package resolve`.

---

## Stage 0 — Sanity check the green core (5 min)

```bash
swift build --product tatlin   # expect: Build of product 'tatlin' complete!  (NOT bare `swift build`)
swift test                     # expect: 88 tests pass
swift run tatlin --help
swift run tatlin models list
```

You should see the four models listed as `available`. This confirms the toolchain before any
heavy lifting.

---

## Stage 1 — Verify live capture + calendar (Phase 1 acceptance)

This is the riskiest macOS unknown and needs real TCC grants + a GUI session — it cannot run in
CI. Do it before the ML work so capture is proven independently.

1. Run a capture from a normal terminal (not over SSH — needs the window server):
   ```bash
   swift run tatlin record          # add --no-calendar to skip the EventKit prompt
   ```
2. Grant the prompts when they appear: **Microphone**, then **Screen & System Audio Recording**.
   - macOS 26 may require a **relaunch** after the screen-recording grant before `SCShareableContent` works. Re-run if the first attempt errors with a permission failure.
3. Play some audio (a YouTube video, a Zoom test call) and speak into the mic. Press **Return** to stop.
4. Inspect the session:
   ```bash
   swift run tatlin sessions
   open ~/Library/Application\ Support/dev.kalambet.tatlin/sessions/<id>/
   ```
   - Confirm `raw-system.wav` (the played audio) and `raw-mic.wav` (your voice) are **both valid and on separate files**, owner clearly isolated on the mic file.
5. While recording, start during a real calendar meeting and confirm `session.json` picks up the event title/attendees; with no meeting, confirm the `Tatlin YYYY-MM-DD HHmm` default.

**Acceptance:** two clean, independently-playable WAVs; survives a mid-session kill (partial WAVs still play); AirPods-as-mic tested.

**Known to confirm on-device** (flagged by the capture author): `SCStream` delegate-at-init form, `captureMicrophone`/`microphoneCaptureDeviceID`, and the resampler frame tolerance on the M5's audio DSP.

---

## Stage 2 — Enable the `TatlinML` target ✅ DONE (2026-06-18)

Already done in-repo: `Package.swift` has the `TatlinML` target + deps active (mlx-swift-lm
pinned **2.x** to match mlx-audio-swift 0.1.2; resolved set committed in `Package.resolved` —
FluidAudio **0.15.4**, mlx-swift 0.31.4, mlx-swift-lm 2.31.3), all `// VERIFY` API gaps are
closed against the resolved sources, and `tatlin run` wires the real engines via
`MLEngineFactory`. `swift build --product tatlin` compiles cleanly.

What got resolved (for the record): `loadAudioArray(from:sampleRate:)` is the audio loader;
`ParakeetModel.fromDirectory(_:)` takes no `computeDType`; `STTOutput.segments` is
`[[String:Any]]` at **sentence** granularity (word-level token timing isn't surfaced by the
public API — see Stage 5); `GenerateParameters(maxTokens:…)` arg order; `ChatSession` has no
`[Chat.Message]` overload (system→`instructions`, rest→`respond(to:)`); FluidAudio 0.15.4 uses
`OfflineDiarizerManager.process(url) -> DiarizationResult` with `.segments` + `.speakerDatabase`.

The first build compiles mlx-swift's Metal kernels (slow, minutes; cached after). Need ~50 GB
free for weights. The detailed per-engine API notes live in `Sources/TatlinML/README.md`.

### 2c. Wire the real engines into the CLI
In `Sources/tatlin/RunCommand.swift`, add `import TatlinML` and replace the body of
`EngineFactory.make()` (it returns an `Engines` struct; `MLEngineFactory.make` returns a tuple):

```swift
static func make(modelStore: ModelStore) -> Engines {
    let trio = MLEngineFactory.make(store: modelStore, asrBackend: .parakeet)
    return Engines(asr: trio.asr, diarizer: trio.diarizer, llm: trio.llm)
}
```
and in `Run.run()` build the store and pass it:
```swift
let modelStore = ModelStore(sessionStoreRoot: store.root)
let engines = EngineFactory.make(modelStore: modelStore)
```
(Keep the stub path behind a `--stub` flag if you want offline pipeline runs.)

---

## Stage 3 — Download model weights

```bash
swift run tatlin models download parakeet-tdt-0.6b-v3                 # ~2.5 GB, ungated (primary ASR)
swift run tatlin models download qwen3-30b-a3b-instruct-2507-mlx-8bit # ~32.5 GB, ungated (summarizer)

# Diarizer: community-1 is CC-BY-4.0 and GATED. Accept the license first:
#   https://huggingface.co/FluidInference/speaker-diarization-community-1
export HF_TOKEN=<your-token>
swift run tatlin models download speaker-diarization-community-1
swift run tatlin models list                                          # all should read "installed"
```

> The manifest's per-file URLs are filled for Parakeet/Qwen; **Voxtral + community-1 file lists
> and all `sha256` values are still TODO** (`Sources/TatlinKit/Models/ModelManifest.swift`). A
> `tatlin models verify` subcommand to record checksums after download is **not implemented yet**
> — it's a small follow-up; until then, treat downloads as unverified.

---

## Stage 4 — First real pipeline run

```bash
# Use a session captured in Stage 1 (or re-record):
swift run tatlin sessions
swift run tatlin run <session-id> --vault ~/Obsidian/Meetings
open ~/Obsidian/Meetings/<title>.md
```
Expect a real diarized, speaker-attributed transcript + structured notes. Re-run individual
stages with `--from-stage transcription|diarization|alignment|summarization|output`.

Sequential residency (`ModelHost`) loads/unloads ASR → diarizer → LLM so peak memory stays well
under 64 GB. Watch memory in Activity Monitor on the first long-meeting run.

---

## Stage 5 — Settle the model decisions with real data (the eval debt)

The model picks (Parakeet over Voxtral; community-1; Qwen3) are evidence-backed priors, **not yet
confirmed on your audio** (research.md Q2/Q3/Q6 + Cross-Cutting Risk #3).

1. **ASR bake-off:** transcribe a few representative clips (incl. RU/DE/EN code-switch) with
   Parakeet and Voxtral; score WER:
   ```bash
   swift run tatlin eval wer --reference ref.txt --hypothesis hyp.txt
   ```
   Adopt Voxtral only if its code-switch WER clearly wins AND you accept building its timestamp
   extraction (it currently returns no word timestamps — see `VoxtralEngine.swift`).
2. **Diarization DER:** hand-label speaker turns for 1–2 real meetings and compute DER
   (`TatlinKit/Eval/DER.swift`) to confirm community-1 on your cross-talk.
3. **Summary golden set:** the dev-only `tools/eval-golden/` Python harness (Part F #5, not yet
   created) generates reference summaries to score Qwen3 against.
4. Empirically set the **FluidAudio enrollment similarity threshold** (`EnrollmentStore`) — its
   default is a guess.

---

## Stage 6 — Phase 3 (the app)

Once the CLI pipeline is good on real audio, build the product shell (plan.md Phase 3):
menubar `MenuBarExtra` + two-state icon, `SMAppService` login item, first-run permission
onboarding (incl. optional Calendar), event picker window, auto-trigger on capture stop,
speaker-naming UI, Settings (vault path / skip-list / output language), icons (Icon Composer),
Developer-ID notarization + GitHub Releases.

---

## Quick reference — current CLI

| Command | Status |
|---|---|
| `tatlin sessions [--resumable]` | ✅ working |
| `tatlin calendar` | ✅ (needs Calendar grant) |
| `tatlin record` | ✅ code-complete (needs grants; verify Stage 1) |
| `tatlin models list` / `download <key>` | ✅ working (`verify` TODO) |
| `tatlin eval wer --reference --hypothesis` | ✅ working |
| `tatlin run <id> [--from-stage] [--vault] [--stub]` | ✅ real engines by default; `--stub` = offline dry run |
