# Tatlin — On-Device Bring-Up Guide

Everything built so far (`scaffold` → Phase 2) compiles and is unit-tested in CI with **stub
engines**. This guide is the ordered checklist for taking it onto the **M5 Pro (macOS 26)** and
getting a real meeting → real notes. Do the steps in order; each is independently testable.

> Quick status: `swift build` + `swift test` (88 tests) are green today with stubs. The real
> ML engines (`Sources/TatlinML/`) are written but **not yet compiled** — Stage 2 below is where
> that happens. Detailed per-API notes live in `Sources/TatlinML/README.md`.

---

## Stage 0 — Sanity check the green core (5 min)

```bash
swift build          # expect: Build complete!
swift test           # expect: 88 tests pass
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

## Stage 2 — Enable the `TatlinML` target

This pulls the heavy MLX/Metal graph (first resolve/build is slow — minutes). Need ~50 GB free.

### 2a. `Package.swift` — uncomment the deps and target
In the `dependencies:` array, uncomment the four ML packages. **Use `mlx-swift-lm`, not
`mlx-swift-examples`** (the `MLXLLM`/`MLXLMCommon` products moved there):

```swift
.package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "2.29.1"),
.package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", from: "0.1.2"),
.package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.9.1"),
.package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
```

Uncomment the `TatlinML` target. Fix the product names to match what `swift package describe`
actually reports after resolving (the commented stub guessed `MLXAudio`; the real products are
likely `MLXAudioSTT` + `MLXAudioCore`, and the LLM package is `mlx-swift-lm`):

```swift
.target(
    name: "TatlinML",
    dependencies: [
        "TatlinKit",
        .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
        .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "FluidAudio", package: "FluidAudio"),
        .product(name: "WhisperKit", package: "WhisperKit"),
    ]
),
```

Add `TatlinML` to the `tatlin` executable target's `dependencies`.

```bash
swift package resolve
swift package describe | grep -i product   # confirm exact product names; fix Package.swift if needed
```

### 2b. Close the `// VERIFY` API gaps
`TatlinML` was written against the libraries' published source but **could not be compiled**, so
~13 API touch-points are marked. Build and fix them iteratively:

```bash
swift build 2>&1 | tee /tmp/tatlinml-build.log    # first compile will surface the real errors
grep -rn "VERIFY" Sources/TatlinML/                 # the checklist, each with a source URL
```
Full annotated list with source links: **`Sources/TatlinML/README.md` → "Known Gaps / VERIFY items"**. The high-priority ones: Parakeet `STTSegment.words` vs `.tokens`, the audio-load helper name, the `mlx-swift-lm` `loadContainer`/`ChatSession` API, and FluidAudio's `exposeChunkEmbeddings` / `embedding256` names.

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
| `tatlin run <id> [--from-stage] [--vault]` | ✅ with stubs; real engines after Stage 2 |
