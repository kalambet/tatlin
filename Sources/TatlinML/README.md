# TatlinML — Concrete ML Engine Conformances

`TatlinML` contains the real MLX/FluidAudio engine implementations for the three pipeline seams
(`ASREngine`, `DiarizerEngine`, `LLMEngine`) declared in `TatlinKit`.  It is **excluded from
the default build** because it pulls the heavy MLX/Metal transitive graph and requires several
gigabytes of downloaded model weights.

The default `swift build` / `swift test` remain green with the stub engines in
`Sources/TatlinKit/Engines/StubEngines.swift`.

---

## Step 1 — Prerequisites

1. **macOS 26 (Tahoe) on Apple Silicon**.  The Metal/ANE kernels in mlx-swift and FluidAudio
   require Apple Silicon; Intel builds are not supported.

2. **Xcode 26 / Swift 6.2** (or the matching Command Line Tools).

3. **~50 GB free disk space** for model weights + working copies.

4. **Hugging Face account** — the FluidAudio diarization models are CC-BY-4.0 gated on HF.
   Accept the license at https://huggingface.co/FluidInference/speaker-diarization-community-1
   before downloading.  The Parakeet and Qwen3 models are ungated.

---

## Step 2 — Uncomment the TatlinML target in Package.swift

Open `Package.swift` and make the following two edits:

### 2a. Uncomment the four ML dependencies

```swift
// Before (lines 31–34):
// .package(url: "https://github.com/ml-explore/mlx-swift-examples.git", from: "2.29.1"),
// .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", from: "0.1.2"),
// .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.9.1"),
// .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),

// After:
.package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.3"),
.package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", from: "0.1.2"),
.package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.9.1"),
.package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
```

> NOTE: The original commented-out entry used `mlx-swift-examples` for MLXLLM.  As of 2026
> those products have moved to the separate `mlx-swift-lm` package (v3.31.3+).  Use the URL
> `https://github.com/ml-explore/mlx-swift-lm.git` instead.

### 2b. Uncomment the TatlinML target

```swift
// Before:
// .target(
//     name: "TatlinML",
//     dependencies: [
//         "TatlinKit",
//         .product(name: "MLXAudio", package: "mlx-audio-swift"),
//         .product(name: "MLXLLM", package: "mlx-swift-examples"),
//         .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
//         .product(name: "FluidAudio", package: "FluidAudio"),
//         .product(name: "WhisperKit", package: "WhisperKit"),
//     ]
// ),

// After:
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

> The products `MLXAudioSTT` and `MLXAudioCore` replace the generic `MLXAudio` product name.
> Verify the exact product names against the installed version of mlx-audio-swift by running
> `swift package describe` after resolving.

### 2c. Add TatlinML to the `tatlin` executable target

```swift
.executableTarget(
    name: "tatlin",
    dependencies: [
        "TatlinKit",
        "TatlinML",          // Add this line
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
    ]
),
```

---

## Step 3 — Swap EngineFactory in RunCommand.swift

`Sources/tatlin/RunCommand.swift` currently calls `EngineFactory.make()` which returns the
stub engines.  To activate the real engines, **do not modify `RunCommand.swift` directly** —
instead add this factory shim to your run command or `tatlin.swift` entry-point:

```swift
// In Sources/tatlin/RunCommand.swift, replace the EngineFactory.make() call:

// Before:
let (asr, diarizer, llm) = EngineFactory.make()

// After:
let store = ModelStore(root: SessionStore.applicationSupportURL)
let (asr, diarizer, llm) = MLEngineFactory.make(store: store, asrBackend: .parakeet)
```

Then add `import TatlinML` at the top of the file.

---

## Step 4 — Download model weights

Run the download CLI subcommand (implemented in `tatlin models download`):

```bash
# Primary ASR — Parakeet-TDT-0.6B-v3 (~2.5 GB, ungated)
swift run tatlin models download parakeet-tdt-0.6b-v3

# Diarization — community-1 (gated CC-BY-4.0; accept license on HF first)
# FluidAudio downloads this automatically via prepareModels(); Tatlin records it for attribution.
# Ensure you have accepted the license at:
#   https://huggingface.co/FluidInference/speaker-diarization-community-1
# then set HF_TOKEN if needed:
export HF_TOKEN=<your-token>
swift run tatlin models download speaker-diarization-community-1

# Summarizer — Qwen3-30B-A3B 8-bit (~32.5 GB, ungated)
swift run tatlin models download qwen3-30b-a3b-instruct-2507-mlx-8bit
```

Minimal-mode download (ASR only, for early capture + transcript testing):

```bash
swift run tatlin models download parakeet-tdt-0.6b-v3
# Diarizer and LLM can be deferred; stages 3–6 will be skipped until downloaded.
```

---

## Step 5 — Verify checksums

After download, record SHA-256s for security and crash-recovery:

```bash
swift run tatlin models verify
```

This command reads `ModelManifest.default`, computes SHA-256 for each present file, and
writes them back into a local `models-manifest-verified.json` in Application Support.
Update the `sha256:` fields in `ModelManifest.swift` from that output before shipping.

---

## Model Licensing Summary

| Model | License | Gated? | Attribution required |
|---|---|---|---|
| Parakeet-TDT-0.6B-v3 (mlx-community fork) | CC-BY-4.0 | No | NVIDIA + mlx-community |
| Voxtral-Mini-4B-Realtime-2602 | Apache-2.0 | No | Mistral AI |
| speaker-diarization-community-1 | CC-BY-4.0 | Yes | pyannote + WeSpeaker + FluidInference |
| Qwen3-30B-A3B-Instruct-2507-MLX-8bit | Apache-2.0 | No | Qwen Team / Alibaba Cloud |
| WhisperKit large-v3 (fallback) | MIT | No | OpenAI + Argmax |

Show attribution in the app's Licenses screen (plan.md M3.8).

---

## Known Gaps / VERIFY items

The following items could not be confirmed from source inspection and must be resolved
when the TatlinML target is first compiled on device:

1. **`ParakeetModel.fromDirectory(_:computeDType:)`** — confirmed exists from code inspection.
   Exact signature needs verification against compiled `.swiftmodule`.  Source:
   https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/Parakeet/ParakeetModel.swift

2. **`STTSegment` property names** — word-level timing is confirmed to exist (tokens carry
   `.start` and `.duration` in seconds via `ParakeetAlignedToken`), but the exact property
   names on the public `STTSegment` / `STTWord` types need verification.
   If `.words` is named `.tokens`, update `ParakeetEngine.mapToTranscript`.
   Source: ParakeetModel.swift (same as above)

3. **`AudioUtils.loadAudioFile(url:sampleRate:)`** — the mlx-audio-swift audio loading helper.
   The exact function name may differ.  Source:
   https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioCore/AudioUtils.swift

4. **`VoxtralRealtimeModel` type name** — may be `VoxtralMini4BRealtime` or `VoxtralRealtime`.
   Source:
   https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/VoxtralRealtime/VoxtralRealtime.swift

5. **`MLX.GPU.clearCache()`** — the exact API to flush the Metal memory cache between stages.
   May be `MLX.GPU.set(cacheLimit: 0)` or a different function.
   Source: https://github.com/ml-explore/mlx-swift (check GPU.swift)

6. **`LLMModelFactory.shared.loadContainer(configuration:)`** — the mlx-swift-lm entry-point
   for loading from a local directory URL.  The factory pattern was confirmed but the exact
   receiver (`LLMModelFactory.shared` vs a free function) needs verification in v3.31.3.
   Source: https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLLM/LLMModelFactory.swift

7. **`ChatSession(_, generateParameters:)`** — the init overload accepting `GenerateParameters`.
   The base `init(_ model:)` is confirmed.  The `generateParameters` label may differ.
   Source: https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/ChatSession.swift

8. **`ChatSession.respond(to: [Chat.Message])`** — the overload accepting a `[Chat.Message]`
   array.  If only `respond(to: String)` exists, format all messages into a single string.
   Source: https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/ChatSession.swift

9. **`OfflineDiarizerConfig.exposeChunkEmbeddings`** — property name confirmed from code
   inspection; verify it is mutable (not a let constant) in the installed version.
   Source: https://github.com/FluidInference/FluidAudio/blob/main/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerManager.swift

10. **`ChunkEmbedding.embedding256`** — property name for the 256-d embedding vector.
    May be named `.embedding`, `.vector`, or `rho128` for the reduced form.
    Source: same as #9.

11. **`DiarizationResult.segments` element `.speakerId`** — field names confirmed from
    the FluidAudio README example code.  Verify against compiled module if attribution changes.
    Source: https://github.com/FluidInference/FluidAudio/blob/main/README.md

12. **`ModelConfiguration(directory:)`** init — the `Identifier.directory(URL)` init path
    in mlx-swift-lm v3.31.3.  If the API changed, use `ModelConfiguration(id: "...", directory: url)`.
    Source: https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/ModelConfiguration.swift

13. **Parakeet HF license** — mlx-community/parakeet-tdt-0.6b-v3 shows CC-BY-4.0 on HF
    (not Apache-2.0 as on NVIDIA's original card).  Verify which license applies to the
    mlx-community conversion before shipping attribution.
