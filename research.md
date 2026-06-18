# Tatlin — Research Findings (Phase 0)

> Resolves the §9 open questions of `tatlin-project-brief_1.md`. Research date: **2026-06-16**.
> Target: MacBook **M5 Pro, 64 GB**, **macOS 26 "Tahoe"** (26.4.x current; successor to macOS 15 Sequoia).
> Status: **architecture decisions SIGNED OFF (2026-06-16)** — see [§Decisions](#decisions-signed-off). Ready for the Plan phase.

---

## TL;DR — Headline Decisions

| Stage | Decision | Confidence |
|---|---|---|
| **Capture** | `ScreenCaptureKit` `SCStream` for **both** system audio + mic (separate `CMSampleBuffer` streams). Two mono 48 kHz WAV files per session. Resample → 16 kHz mono at ASR time. | High |
| **ASR** | ⚠️ **Open Voxtral cannot emit usable timestamps** — blocks alignment. **Locked: Parakeet-TDT-0.6B-v3 via mlx-audio-swift** (native Swift, word timestamps, RU/DE/EN) as primary, with a **bake-off vs Voxtral-Mini-4B-Realtime-fp16**; **WhisperKit large-v3** as hard fallback. Accepted C2 exception. | High |
| **Diarization** | **FluidAudio** `OfflineDiarizerManager` = **pyannote community-1** (powerset segmentation + WeSpeaker + VBx). **Not Sortformer** (hard 4-speaker cap). | High |
| **Alignment** | whisperX-style **word-level max-overlap assignment** + interval-tree lookup. Owner-mic channel merged by precedence. | High |
| **Speaker ID** | Layered: **owner-mic anchor** (deterministic) → **enrolled embeddings** (recurring) → **LLM relabel** (one-off, evidence-gated). | High |
| **Summarization** | C2 lifted here → **Qwen3-30B-A3B-Instruct-2507-MLX-8bit** (MoE, ~32 GB, 262k ctx, non-thinking, best open RU) in-process via mlx-swift. Mistral Small 3.2 / Magistral are fallbacks. **Sequential** stage load/unload. | High |
| **Packaging** | SwiftUI `MenuBarExtra` + `SMAppService.mainApp` login item, `LSUIElement=YES`. **Download models on first run** (≈15–25 GB total) into Application Support. | High |
| **Icons** | macOS 26 `.icon` (Icon Composer) for the app, near-black bg; PDF template + red dot for the menubar capture state. | High |

---

## ✅ Decisions (Signed Off)

Signed off by owner on **2026-06-16**:
- **D1 — ASR:** **Parakeet-TDT-0.6B-v3** (mlx-audio-swift) as primary, with a **bake-off vs Voxtral-Mini-4B-Realtime-fp16** on real code-switched audio. Accepts ASR as a C2 exception (like diarization).
- **D2 — Diarization:** **FluidAudio `OfflineDiarizerManager` → pyannote community-1**.
- **D3 — Summarizer:** **`lmstudio-community/Qwen3-30B-A3B-Instruct-2507-MLX-8bit`** (C2 lifted for this stage). English-dominant meetings; RU/DE a free safety margin.

Detail and rationale below.

### D1 — ASR model: the C2 constraint is in tension with reality (BIGGEST DECISION)
Constraint **C2** mandates **Voxtral** (a Mistral model) for ASR. Research finding: **the open-weights Voxtral models do not emit usable word/segment timestamps**, which the diarization-alignment stage (§5.3) hard-requires.
- The word-timestamps everyone cites belong to **Voxtral Mini Transcribe V2 — closed, API-only** (disqualified by local-only).
- Open **Voxtral-Mini-4B-Realtime** is timing-*aware* internally (`[W]` word-boundary tokens at 80 ms frames) but **no library exposes timestamps today**; extracting them means forking the decoder — real, unvalidated work in Swift.

**Options:**
- **(A) Recommended — Parakeet-TDT-0.6B-v3** via `mlx-audio-swift`: native Swift, word-level timestamps out of the box, RU/DE/EN (+22 langs), ~1.5 GB, WER competitive with Voxtral. **Departs from C2** (Parakeet is NVIDIA, not Mistral).
- **(B) Voxtral-Mini-4B-Realtime-fp16** (Apache-2.0, ~8.9 GB) + build custom `[W]`-token timestamp extraction *or* a forced aligner (Qwen3-ForcedAligner, in mlx-audio-swift). Honors C2; costs engineering + risk. Likely best for heavy **intra-sentence RU/DE/EN code-switching**.
- **(C) WhisperKit large-v3** (MIT, mature CoreML/ANE): word timestamps built in, strong RU/DE/EN. Safest fallback; also departs from C2.

> The C2 exception clause already accepts one non-Mistral model (diarization). The ASR timestamp gap is an analogous, arguably unavoidable, deviation. **Recommendation: ship on Parakeet (A), run a bake-off vs Voxtral (B) on real code-switched audio, adopt Voxtral only if code-switching WER clearly wins and you accept the timestamp work.** Need your call on whether C2 can flex here.

### D2 — Diarization backend
**Recommend FluidAudio community-1 offline pipeline.** Sign-off requested (this is the other decision the brief calls out explicitly). Rationale in [§Q3](#q3--diarization-backend).

### D3 — Summarizer: C2 lifted — any open model
Per owner decision (2026-06-16), the summarizer is **no longer constrained to Mistral**. Across Qwen3 / Gemma 3 / Mistral, the best fit is **`lmstudio-community/Qwen3-30B-A3B-Instruct-2507-MLX-8bit`**: best open **Russian** (your weakest-covered language), MoE (~3.3B active → ~8B-class speed at 30B quality), **non-thinking instruct** (no `<think>` traces to strip → clean Markdown), 262k context, proven mlx-lm/text-only MLX support. Fallbacks: Mistral-Small-3.2-24B-8bit (weaker RU) or Qwen3-32B dense (slower). **Avoid the newest Qwen3.5/3.6 + Gemma 4** for now — they ship as VLM checkpoints with immature/buggy mlx-swift text loaders and a reported structured-output regression. See [Q6](#q6--summarization-llm-in-swift).

---

## Q1 — Audio Capture

**Recommendation: `ScreenCaptureKit` (`SCStream`) for both system audio and the mic.**

- `SCStreamConfiguration`: `capturesAudio = true`, `captureMicrophone = true` (mic support added macOS 15), `microphoneCaptureDeviceID = <mic>`, `excludesCurrentProcessAudio = true`, minimal 2×2 video (a video track is required; discard frames).
- Delivers **separate callbacks**: `.audio` (system output — Zoom/Teams/Meet/FaceTime) and `.microphone` (owner). This *is* the channel separation the brief wants.
- **Why SCStream over Core Audio process taps (CATap):** per-process CATap **silently returns zero-filled buffers for WebRTC apps (Teams/Zoom/Meet)** — the exact meeting apps Tatlin targets. A *global* CATap captures them but also grabs music/notifications. SCStream reliably captures meeting-app audio. (Apple DTS recommends CATap for pure audio-only, but the WebRTC failure is disqualifying here.) Keep a global CATap as a possible v2 fallback.

**Channel separation / format:**
- Write **two separate mono WAV files** per session: `<id>-system.wav` and `<id>-mic.wav`, **48 kHz / 32-bit float** (native; avoid resampling at capture). Two files is simpler than a multi-track container and avoids the confirmed `AVAssetWriterInput` clock-sync corruption when mixing two formats into one container.
- **Resample to 16 kHz mono float32 in memory via `AVAudioConverter` at ASR time** (Voxtral/Parakeet/Whisper all want 16 kHz mono). Keep the 48 kHz originals for re-transcription.

**Permissions:** `NSScreenCaptureUsageDescription` (Screen & System Audio Recording) + `NSMicrophoneUsageDescription` (Microphone). Two TCC grants, one framework. No special/restricted entitlement.

**Headless/launchd:** Yes — package as `.app` with `LSUIElement=YES`, register as login item via `SMAppService` (not a bare LaunchAgent — see [Q7](#q7--packaging-lifecycle-permissions-models)). Bare executables don't appear in the Tahoe 26.1 privacy UI (confirmed bug); always ship an `.app` bundle.

**Risks:** SCStream `-3805`/`connectionInvalid` errors + EXC_BAD_ACCESS in long sessions → add a stalled-callback watchdog that restarts the stream and flushes the WAV. AVAudioEngine `installTap` doesn't fire for Bluetooth mics on macOS 26 (SCStream's `microphoneCaptureDeviceID` path may be fine — test AirPods). macOS 15+ prompts to re-approve screen recording **monthly** — unavoidable; explain in onboarding.

Sources: Apple DTS forums (corrupt-output-with-mic, audio-capture-API), `insidegui/AudioCap`, Rogue Amoeba Tahoe audio bug-fix writeup (2025-11), creavit.studio SCK guide. Full URLs in agent transcript.

---

## Q2 — ASR (Voxtral) in Swift

**The critical finding is the timestamp gap — see [D1](#d1--asr-model-the-c2-constraint-is-in-tension-with-reality-biggest-decision).**

- **Swift maturity:** `Blaizzy/mlx-audio-swift` (v0.1.x, ~675★) supports **Voxtral Realtime (Mini-4B fp16)** and **Parakeet** for batch file transcription — so Swift ASR is real, but pre-1.0 (API churn, thin docs; pin the version). The dedicated `mlx-voxtral` Python repo still lists "Swift library" as a TODO.
- **Timestamps (blocker for open Voxtral):** Voxtral-Mini-3B-2507 transcription returns **text only** (HF feature request #35 unresolved). Decoders call `skip_special_tokens=True`, discarding the `[W]` boundary tokens. Word times *are* derivable (`t ≈ frame_idx × 80 ms − transcription_delay`) but no library does it — custom decoder fork required.
- **Best multilingual choice:** **Parakeet-TDT-0.6B-v3** — RU/DE/EN +22 EU langs, **native word timestamps**, ~1.5 GB (bf16), WER ~6.3% clean. Per-segment language-ID, so weaker on *intra-sentence* code-switching than Voxtral. Voxtral-Mini-4B-Realtime (FLEURS WER RU 6.02 / DE 6.19 / EN 4.90 at 480 ms) is the better code-switcher *if* you solve timestamps.
- **Audio input:** 16 kHz mono, 16-bit/float. 4B-Realtime context ~131k tokens ≈ 3 h → 1–2 h meetings fit, but expect internal 30 s chunking; validate seam stitching.
- **Memory (64 GB has ample room):** Voxtral 4B fp16 ~8.9 GB (no need to quantize — 4-bit measurably hurts multilingual WER); 4-bit ~3–4 GB; Parakeet bf16 ~1.5 GB.
- **Fallback ladder:** Parakeet (mlx-audio-swift) → **WhisperKit/argmax-oss-swift v1.0.0** (MIT, most mature, word timestamps, now bundles SpeakerKit diarization) → mlx-voxtral via subprocess (last resort, violates no-Python).

**Action:** bake-off Parakeet vs Voxtral-4B-fp16 on real Tatlin code-switched audio before locking.

Sources: mlx-audio-swift & mlx-audio repos, Voxtral-Mini-4B-Realtime-2602 HF card, Voxtral Realtime paper (arXiv 2602.11298), Parakeet-TDT-0.6b-v3 HF card, WhisperKit/argmax-oss-swift, Mistral STT docs (timestamps = closed Transcribe V2). URLs in agent transcript.

---

## Q3 — Diarization Backend

**Recommendation: FluidAudio `OfflineDiarizerManager` → pyannote community-1** (powerset segmentation + WeSpeaker embeddings + VBx clustering), all CoreML/ANE.

- Batch design means we can use the most accurate **offline, overlap-aware** path. community-1 is genuinely overlap-aware (≤3 concurrent speakers/frame), **no hard speaker cap**, beats pyannote 3.1 on AMI/AliMeeting/DIHARD-3. FluidAudio reports ~13.9% DER (max-accuracy) / ~15% at 122× real-time on M2 Air → <1 min for 1–2 h on M5.
- **Reject Sortformer as primary:** hard-capped at **4 speakers**, degrades at 5+ — disqualifying for multi-party meetings. It exists for streaming latency we don't need. Keep only as optional fast-preview. LS-EEND: streaming, weaker. sherpa-onnx: CPU-only, no ANE — deprioritized fallback.
- **Embeddings + enrollment: yes.** FluidAudio exposes per-chunk/per-speaker embeddings on `DiarizationResult` and `speakerManager.initializeKnownSpeakers([...])` for named enrollment. (API churned across 0.14.x/0.15.x — pin version, verify symbol names against installed SPM revision; docs vs DeepWiki disagree on the enrollment surface.)
- **FluidAudio vs speech-swift:** FluidAudio — Apache-2.0, all-ANE offline pipeline purpose-built for batch, frequent releases (~v0.15.x in 2026). speech-swift (soniqo) is MLX-leaning (slower/warmer on long files) but has a clean enrollment-extraction pattern worth borrowing. **Pick FluidAudio.** Keep one embedding backend so enrolled vectors stay comparable.
- **Licensing:** FluidAudio SDK Apache-2.0; **pyannote community-1 weights + the FluidInference CoreML conversion are CC-BY-4.0 and gated on HF** → ship attribution (pyannote + WeSpeaker + FluidInference), add in-app license acceptance, and **vendor the CoreML weights** rather than runtime-fetch from a gated repo. Sortformer (if ever used) is also CC-BY-4.0.
- **Trust the DER numbers cautiously:** FluidAudio's figures are single-file CI benchmarks. **Build a small DER/JER eval harness on representative meeting recordings** before committing.

Sources: FluidAudio repo + docs site + releases, speaker-diarization-community-1 HF card, NVIDIA Sortformer v2 card, soniqo/speech-swift docs. URLs in agent transcript.

---

## Q4 — Alignment (ASR × Diarization)

**Recommendation: whisperX-style max-overlap assignment at word level.**

For each ASR word `[w_start, w_end]`, accumulate temporal intersection against each diarizer turn, assign `argmax` speaker; nearest-turn fallback when no overlap. Then re-group consecutive same-speaker words into display segments.
- **Assign at word level, not segment level** — speaker turns frequently change mid-ASR-segment; word-level reassignment avoids smearing.
- **Sort turns + interval-tree / binary-search lookup**, not O(n·m) (whisperX reported ~228× speedup here). Matters for 1–2 h files.
- **Shared timebase:** resample both to the same clock (16 kHz mono for the diarizer) or intersections drift by frames.

**Overlap handling:** community-1 emits overlapping turns in cross-talk; ASR still transcribes one stream, so max-overlap attributes those words to the **dominant** speaker (standard, imperfect — whisperX has the same gap). Flag `overlap=true` segments (diarizer ≥2 active) as low-confidence in the UI.

**Owner-mic channel merge (recommended):** run VAD/single-speaker diarization on the clean owner channel → high-precision owner intervals; **force-assign those intervals to "Owner" by precedence** over the room-mix diarizer. Recovers owner words during cross-talk and pins owner identity deterministically.

Source: whisperX repo + `assign_word_speakers` interval-tree issue #1335.

---

## Q5 — Speaker Identity

**Layered, cheapest/most-reliable first:**
1. **Owner via mic-channel anchor (deterministic, ~100%).** The diarized cluster aligning to the owner channel = owner. Resolve in the diarization stage.
2. **Recurring participants via enrolled embeddings (FluidAudio).** Enroll reference embeddings once; `initializeKnownSpeakers` names matched clusters on future meetings. **Self-improving:** when a name is confirmed (by user or high-confidence LLM), save that cluster's embedding as a new profile. Use a conservative similarity threshold (verify empirically — FluidAudio doesn't publish it); treat near-misses as unknown.
3. **One-off unknowns via LLM context relabel (best-effort, low trust).** The summarizer proposes names from cues ("Thanks, Anna", self-intros) and returns a `speaker_name_map` with **per-mapping evidence + confidence**. High-confidence+evidence → apply as *"Anna (inferred)"*; low → keep `Speaker N`. Never silently fabricate; offer one-tap correction that feeds layer 2.

**Risk:** directional address is ambiguous and the LLM will confidently hallucinate — evidence-gating, confidence flags, and human correction are mandatory.

---

## Q6 — Summarization LLM in Swift

> **C2 lifted for this stage** (owner decision, 2026-06-16): the summarizer may be any open-weights model, not only Mistral. Broadened comparison across Qwen3 / Gemma 3 / Mistral.

**Recommendation: `lmstudio-community/Qwen3-30B-A3B-Instruct-2507-MLX-8bit`** (MoE, ~32.4 GB, 262 k context).
- **Why #1:** simultaneously satisfies (1) **best open Russian** (Qwen leads RU/DE/EN; RU is your weakest-covered language and the deciding factor), (2) **proven in-process MLXLLM support** — converted with **mlx-lm** (text-only, no VLM key mismatch), backed by the mature `Qwen3MoE.swift` loader, (3) **non-thinking instruct → no `<think>` trace to strip**, clean Markdown, (4) MoE with **~3.3 B active params** → ~8B-class speed at 30B-class quality, ideal once ASR/diarizer are unloaded, (5) 262 k context (1 M w/ YaRN). **8-bit** (not 4-bit — MoE 4-bit measurably hurts instruction-following; 64 GB has the room).
- **Fallbacks (ranked):** Qwen3-32B dense 8-bit (highest single-model quality but ~10× slower, hybrid-thinking must be disabled) → Mistral-Small-3.2-24B-Instruct-2506-8bit (~25 GB, proven `Mistral3Text.swift`, but **weaker RU**). Gemma-3-27B-it is proven on MLX but its per-language RU trails Qwen.
- **Avoid for now:** **Qwen3.5 / Qwen3.6 / Gemma 4** — ship as unified **VLM checkpoints** (mlx-vlm); the matching mlx-swift text loaders are Feb–May 2026 additions with open breakage reports (mlx-swift-lm #282, mlx-swift #389) and a reported **structured-output regression** in the Qwen3.5 MLX quants (mlx-lm #1011). Revisit once a text-only mlx-lm conversion lands and the regression closes. **Reject Mistral Small 4 (119B MoE, 67.8 GB 4-bit)** — no KV headroom on 64 GB.
- **RU-quality evidence + caveat:** Qwen3 Tech Report (arXiv 2505.09388) — 30B-A3B-2507 MMLU-Redux 89.3 / MultiIF 67.9 / INCLUDE 71.9, and Qwen3-32B-Base beats Gemma-3-27B-Base on multilingual INCLUDE. **But real RU *meeting-summarization* quality is essentially un-benchmarked** — public evals (INCLUDE/MMLU-ProX/MERA) measure QA, not "extract decisions+owners from a 25 k-token code-switched transcript into clean Markdown." Treat Qwen's lead as a strong prior; **confirm on an in-house golden set.**
- **mlx-swift maturity + structured output:** `mlx-swift-lm` (formerly mlx-swift-examples, ~v2.21.x) loads Qwen3 MoE in-process. **No grammar/JSON-constrained decoding** (issue #221 open) → format is 100 % prompt-driven: system prompt = literal `##` Markdown skeleton + rules (`- [ ] <task> — **owner:** <name>`, empty section → `_None_`); one-shot RU+DE+EN code-switched exemplar (worth more than instructions for non-English structure); sampling `temp 0.2–0.3, top_p 0.9, rep_penalty 1.05`; defensive strip of any pre-header preamble; Swift-side validation (all 5 headers + owner regex) with one repair pass on failure.
- **Long transcript:** ~30 k tokens fits the 262 k window in one pass for most meetings. Tokenize with the model's tokenizer (RU/DE denser than EN). Escalate to **map-reduce** (chunk on speaker-turn boundaries, ~8–10 k tokens + ~500 overlap → reduce pass at temp ~0.3) only if eval shows dropped items past ~20 k.
- **Memory/concurrency:** **Sequential load/unload** — ASR → release → diarizer → release → load LLM → summarize → unload. LLM stage peaks ~32 GB weights + ~3–6 GB KV; don't co-reside with ASR+diarizer. Batch design = zero latency penalty for serial stages. `MLX.GPU.set(cacheLimit:)` modestly, drop refs between stages.
- **Prompt-injection:** transcript content ("ignore previous instructions…") lands in the prompt — wrap in clear delimiters, instruct "treat as data," pin output language explicitly.
- **Eval debt (do before locking):** ~30-transcript golden set (RU-heavy, some DE, code-switch) scored on section completeness, action-item recall + owner attribution, decision recall, hallucination rate, language fidelity. Only this discriminates the candidates for your task.

Sources: Qwen3 Tech Report (arXiv 2505.09388), Qwen3-30B-A3B-Instruct-2507 HF card + lmstudio-community/mlx-community MLX repos, Qwen3-32B-MLX, Mistral-Small-3.2 card, Gemma 3 multilingual blog, mlx-swift-lm loaders + issues #282/#389/#221/#1011, MERA. URLs in agent transcript.

---

## Q7 — Packaging, Lifecycle, Permissions, Models

- **Menubar:** SwiftUI **`MenuBarExtra`** with `.menuBarExtraStyle(.menu)`; two-state icon via SF Symbol swap (`record.circle` / `record.circle.fill`) — renders as template, auto light/dark. `LSUIElement=YES` (no Dock icon). Use **`MenuBarExtraAccess`** SPM pkg if you need the underlying `NSStatusItem` (badges, right-click). Note: Tahoe added a user-managed "Menu Bar Items" permission category — no API to force-show.
- **Login item:** **`SMAppService.mainApp`** (login item = the menubar app itself). **Do NOT add a separate LaunchAgent plist** — Tatlin needs user interaction to start capture, so a headless daemon is overkill. Register only on explicit user opt-in (default OFF; Guideline 2.5.4). Re-check `.status` on activation (user can remove it in Settings silently).
- **First-run permissions (sequential):** request **Microphone** first (`AVCaptureDevice.requestAccess(for:.audio)`), then **Screen & System Audio Recording** (`SCShareableContent` triggers prompt / `CGRequestScreenCaptureAccess`). After screen grant, **app must relaunch** for TCC to take effect in `SCShareableContent` — show a "Restart required" banner. Don't gate launch; show a warning badge + Settings deep-link (`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`) if missing. Onboarding must explain the **monthly** re-auth prompt and that an audio app needs *Screen* Recording permission.
- **Models — download on first run, do NOT bundle** (LLM alone ~13–26 GB; App Store 4 GB limit). Store in `~/Library/Application Support/Tatlin/models/{asr,diarization,llm}/`. Use **background `URLSession`** (resumable) for multi-GB safetensors; **SHA-256 verify** against a bundled `models-manifest.json`; compile CoreML via `MLModel.compileModel(at:)` and cache `.mlmodelc`. Downloaded files are user data — **no notarization/quarantine** issues (but never ship a *bundled* `.mlpackage` carrying `com.apple.quarantine` — App Store rejects it). Gated HF models (pyannote, possibly Mistral) need in-app license acceptance. Offer a **minimal mode** (small ASR first) so capture works before the LLM finishes downloading.
- **Crash safety / layout:**
  ```
  ~/Library/Application Support/Tatlin/
    models/{asr,diarization,llm}/...
    sessions/<timestamp>/raw-system.wav, raw-mic.wav, transcript.json,
                          diarization.json, notes.md, session.json
    downloads/*.tmp + *.progress
  ```
  Open the session dir + WAV files the instant the user clicks Start. Each stage writes its artifact before the next begins → fully re-runnable; surface "Resume" for sessions with audio but missing later artifacts.

Sources: macOS 26 MenuBarExtra refs (nilcoalescing, sarunw, TahoeMenuDemo), MenuBarExtraAccess, SMAppService guides, CoreML on-device compile docs, WWDC23 resumable transfers, Sequoia monthly-prompt coverage. URLs in agent transcript.

---

## Q8 — Icons

- **App icon (macOS 26):** author in **Icon Composer** (Xcode 26) → `Tatlin.icon` (1024², layered SVG; converts to `Assets.car` + `.icns`). Keep a legacy `AppIcon` image set for pre-26. Set **near-black solid background (#0D0D0D)** to honor the black/grey Constructivist aesthetic — Liquid Glass refraction is near-invisible on black (faint metallic specular, which suits the steel lattice). Test all five appearance modes (incl. Tinted wash).
- **Tatlin Tower mark:** tapered leaning (~12°) trapezoid silhouette, **twin counter-wound diagonal helix lattice** (~55° strut families crossing into an X-lattice), with four simplified suspended volumes (cube → pyramid → cylinder → hemisphere) bottom-to-top. Grey strokes `#C8C8C8` (frame/lattice) and `#909090` (volumes) on black. A starter SVG schematic is in the agent transcript — refine the lattice into bezier-clipped tapered strokes for production.
- **Menubar icon:** **PDF vector template** (`isTemplate=true`, "Render As: Template Image"), drawn at 16 pt within a 22 pt slot. Auto light/dark.
  - *Not-capturing:* minimal tower silhouette — tapered outer frame + 2–3 diagonal lattice strokes (no inner volumes — illegible at 16 pt).
  - *Capturing (recommended Option A):* same tower in `NSColor.labelColor` **+ a hardcoded `systemRed` dot** (~4 pt, top-right). Requires a **non-template** image (set `isTemplate=false`) or a SwiftUI `Label` compositing tower + red `Circle()`. The red dot = the universal "recording" convention (additive to macOS's own orange mic indicator). Option B (filled vs outline, pure template) is simpler but a weaker signal.
- **Toolchain:** Figma/Sketch (vector, 1024²) → per-layer SVG → Icon Composer for the app icon; Figma → single PDF → Asset Catalog template for the menubar. Custom SF Symbol only if you later want SF Symbols animations (e.g., pulsing dot).

Sources: WWDC25 #361 (Icon Composer), Bjango menubar-extras guide, NSImage.isTemplate docs, Tahoe Liquid Glass icon writeups, Tatlin's Tower (Wikipedia). URLs in agent transcript.

---

## Cross-Cutting Risks

1. **ASR timestamps (highest)** — open Voxtral can't give them; resolve via D1 before any pipeline work.
2. **Pre-1.0 Swift ML tooling** — mlx-audio-swift v0.1.x, FluidAudio 0.14/0.15 API churn. Pin versions; verify symbols against installed revisions.
3. **DER reality vs marketing** — build your own eval harness on real meeting audio for both diarization and ASR (RU/DE/EN code-switch).
4. **Gated CC-BY models** — vendor weights, ship attribution + in-app license acceptance.
5. **SCStream long-session stability** — watchdog + WAV flush + stream restart.
6. **Memory** — strictly sequential stage load/unload; never co-reside ASR + diarizer + 24B LLM.
7. **Permission UX friction** — monthly screen-recording re-auth, "audio app needs Screen Recording," ~15–25 GB first-run download. All need explicit onboarding copy.

## Suggested Next Steps
1. ✅ Architecture decisions signed off (D1 ASR, D2 diarization, D3 summarizer) — 2026-06-16.
2. Proceed to **Plan** (`plan.md`): ADR + phased milestones, starting with the Phase 1 capture spike (riskiest unknown) and an early ASR bake-off + DER eval harness.
