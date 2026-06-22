# Tatlin — On-Device Bring-Up Guide

Everything built so far (`scaffold` → Phase 2) compiles and is unit-tested in CI with **stub
engines**. This guide is the ordered checklist for taking it onto the **M5 Pro (macOS 26)** and
getting a real meeting → real notes. Do the steps in order; each is independently testable.

> Quick status (updated 2026-06-19): `TatlinML` is **enabled and compiling** against the real
> MLX/FluidAudio APIs — all the original `// VERIFY` gaps are closed (Stage 2 done). Stages 3–4 are
> **done**: weights downloaded (Parakeet, Qwen3, community-1) and the **full real-engine pipeline
> ran end-to-end on a live in-person capture** (2026-06-19 — see the ✅ callout below). What remains:
> the **eval pass** (Stage 5, quality unproven), a **remote-meeting test** of the system-audio
> capture path (recorded silence in-person), and **multi-speaker** validation.
>
> ⚠️ **Build with `swift build --product tatlin`**, not bare `swift build`: FluidAudio's *own*
> `FluidAudioCLI` benchmark target hits a compiler type-check-timeout (a bug in their code, in a
> target we don't use). `swift run tatlin …` and `swift test` are unaffected.
>
> ⚠️ **Dependency resolution needs HTTPS.** Your global git rewrites GitHub→SSH and the 1Password
> SSH agent was refusing to sign, so `swift package resolve` was run with a throwaway
> `GIT_CONFIG_GLOBAL` (empty) to force plain HTTPS. If you re-resolve and it fails on SSH, either
> unlock 1Password or run: `GIT_CONFIG_GLOBAL=/tmp/empty swift package resolve`.
>
> ✅ **MLX inference works — but ONLY via an Xcode build, not `swift run`.** Plain SwiftPM cannot
> compile mlx-swift's Metal shaders, so MLX-backed commands (`tatlin transcribe`, `tatlin run` with
> real engines) fail under `swift run` with *"Failed to load the default metallib."* **Resolved**
> (verified 2026-06-18 — real Parakeet transcription ran successfully) with two one-time steps:
>
> ```bash
> # 1. Xcode 26 ships the Metal Toolchain as a separate component (~688 MB) — install once:
> xcodebuild -downloadComponent MetalToolchain
> # 2. Build via Xcode (compiles + bundles default.metallib):
> xcodebuild -scheme tatlin -destination 'platform=macOS,arch=arm64' \
>   -derivedDataPath .xcode-build -configuration Debug CODE_SIGNING_ALLOWED=NO build
> # 3. Run the Xcode-built binary (the mlx-swift_Cmlx.bundle/default.metallib sits beside it):
> .xcode-build/Build/Products/Debug/tatlin transcribe <audio>
> ```
>
> `swift run`/`swift test` remain the fast path for everything non-MLX (`--stub` pipeline, calendar,
> sessions, eval, downloads). Phase 3 makes this seamless by shipping a real Xcode `.app` (ADR-9).
> Refs: [ml-explore/mlx#2061](https://github.com/ml-explore/mlx/pull/2061),
> [swama#30](https://github.com/Trans-N-ai/swama/issues/30), [jan#8046](https://github.com/janhq/jan/issues/8046).
>
> ✅ **Full real-engine pipeline verified end-to-end (2026-06-19).** A live capture ran
> record → ASR (Parakeet) → diarization (FluidAudio) → alignment → speaker-ID → summarization
> (Qwen3-30B 8-bit MLX) → notes `.md`, all on-device via the Xcode binary, with calendar
> metadata in the frontmatter. Two bugs were fixed to get there:
> 1. **`tatlin run` never loaded model weights** → every real run died with `modelNotLoaded`.
>    `load()`/`unload()` are now part of the `ASREngine`/`DiarizerEngine`/`LLMEngine` protocols
>    and driven through `ModelHost`.
> 2. **In-person recordings need `--source mic`** (see the ⚠️ below).
>
> ⚠️ **System-audio can capture pure silence — use `--source mic` for in-person meetings.**
> The pipeline transcribes + diarizes the **system** channel by default (remote participants);
> the mic is only an owner anchor. In the 2026-06-19 in-person test, `raw-system.wav` was
> digital silence (−91 dB) because nothing was routed through system output — **all speech was on
> `raw-mic.wav`** (−16 dB peak). Default `run` then fails at diarization with *"No speech detected
> in audio."* Fix: `tatlin run <id> --source mic` makes the mic the ASR + diarization source
> (owner-mic VAD is auto-disabled in this mode, since the mic is no longer owner-exclusive —
> owner identity then falls back to enrollment/roster/LLM). Default stays `--source system`.
> **Still unverified:** the system-audio capture path itself — needs a real *remote* meeting where
> audio actually plays through system output, to confirm `raw-system.wav` is non-silent.

---

## Where data lives (CLI vs. app — ADR-9a/ADR-10)

The CLI and the menubar app share the same `SessionStore` / `ModelStore` code but
write to **different physical roots** because the app is sandboxed:

- **CLI** → `~/Library/Application Support/dev.kalambet.tatlin/` (user domain).
- **App** → `~/Library/Containers/dev.kalambet.apps.Tatlin/Data/Library/Application Support/dev.kalambet.tatlin/` (sandbox container).

`FileManager.applicationSupportDirectory` resolves both automatically — no code
branches. Consequence: **model weights download once per store**. The CLI is the
dev/eval surface (`--from-stage`, `tatlin eval …`); the app is what users use.
Use `tatlin clean` to wipe the CLI store between dev runs.

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
   - ⚠️ **Check `raw-system.wav` is not silent** (`ffmpeg -i raw-system.wav -af volumedetect -f null -`): if nothing played through system output it will be ~−91 dB and the default `run` will fail at diarization. For an **in-person** meeting that's expected — process it with `tatlin run <id> --source mic` (see the top-of-file ⚠️).
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
# Use a session captured in Stage 1 (or re-record). Real engines need the Xcode binary:
swift run tatlin sessions
.xcode-build/Build/Products/Debug/tatlin run <session-id> --vault ~/Obsidian/Meetings
#   add --source mic for an in-person meeting (system channel silent — see top-of-file ⚠️)
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

**M3.7 icons ✅ DONE (2026-06-22).** The app icon is the Tatlin Tower (leaning double-helix
truss, constructivist red on cream), authored as parametric SVG in `Tatlin/Design/icon/`
(`tower.py` is the generator — re-render at any size, no external design tool). Full macOS
ladder + iOS dark/tinted variants are in `AppIcon.appiconset`; the menu bar uses monochrome
template PDFs (`MenuBarTower` / `MenuBarTowerRecording`) driven by `AppModel.menuBarIcon`.
Icon Composer `.icon` (macOS 26 Liquid Glass) is optional polish — see the folder README.

---

## Quick reference — current CLI

| Command | Status |
|---|---|
| `tatlin sessions [--resumable]` | ✅ working |
| `tatlin calendar` | ✅ (needs Calendar grant) |
| `tatlin record` | ✅ code-complete (needs grants; verify Stage 1) |
| `tatlin models list` / `download <key>` | ✅ working (`verify` TODO) |
| `tatlin eval wer --reference --hypothesis` | ✅ working |
| `tatlin run <id> [--from-stage] [--vault] [--source system\|mic] [--stub]` | ✅ verified end-to-end with real engines (Xcode binary; 2026-06-19). `--stub` works under `swift run`. Use `--source mic` for in-person (system channel silent) |
| `tatlin transcribe <audio> [--model-key]` | ✅ real Parakeet ASR verified (via Xcode-built binary) |
