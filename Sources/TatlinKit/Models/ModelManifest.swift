import Foundation

/// Describes a single downloadable file within a model bundle.
public struct ModelFile: Codable, Sendable {
    /// Full HTTPS URL for the file (may be a Hugging Face resolve URL).
    /// Empty string = placeholder; fill in before shipping. // TODO: exact HF file URLs + sha256
    public let urlString: String
    /// Hex-encoded lowercase SHA-256 of the file as downloaded.
    /// `nil` = not yet recorded; verification is skipped when nil.
    public let sha256: String?
    /// Byte count of the file on disk (used for download progress estimation).
    public let sizeBytes: Int64?
    /// Path relative to the model's local directory where the file is stored.
    public let relativePath: String

    public init(
        urlString: String,
        sha256: String? = nil,
        sizeBytes: Int64? = nil,
        relativePath: String
    ) {
        self.urlString = urlString
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.relativePath = relativePath
    }
}

/// Broad stage a model belongs to — drives the `models/{asr,diarization,llm}/` layout.
public enum ModelKind: String, Codable, Sendable {
    case asr
    case diarization
    case llm
}

/// Everything needed to download, verify, and reference one model bundle.
public struct ModelSpec: Codable, Sendable {
    /// Stable short key used as the directory name, e.g. "parakeet-tdt-0.6b-v3".
    public let key: String
    /// Human-readable name shown in the UI / CLI, including HF repo id.
    public let displayName: String
    public let kind: ModelKind
    public let files: [ModelFile]
    /// SPDX license identifier, e.g. "Apache-2.0".
    public let license: String

    public init(
        key: String,
        displayName: String,
        kind: ModelKind,
        files: [ModelFile],
        license: String
    ) {
        self.key = key
        self.displayName = displayName
        self.kind = kind
        self.files = files
        self.license = license
    }
}

/// Catalogue of the models Tatlin uses (plan.md ADR-2/3/6, M1B.1).
///
/// HF file URLs are filled in where confirmed from the repository "Files and versions" tab.
/// SHA-256s are intentionally left nil — run `tatlin models verify` after download to record them.
/// Sizes marked // VERIFY need measurement from the downloaded files.
///
/// URL pattern for HF resolve/main: `https://huggingface.co/<repo>/resolve/main/<filename>`
public enum ModelManifest {
    public static let `default`: [ModelSpec] = [

        // MARK: Primary ASR — Parakeet-TDT-0.6B-v3 via mlx-audio-swift
        // HF repo: mlx-community/parakeet-tdt-0.6b-v3  (note: mlx-community fork, not nvidia/)
        // Files verified from https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3/tree/main
        // Total size: ~2.51 GB
        // License: CC-BY-4.0 (model card — note: different from Apache-2.0 on original NVIDIA card)
        // TODO sha256: record after first download with `swift run tatlin models verify`
        ModelSpec(
            key: "parakeet-tdt-0.6b-v3",
            displayName: "mlx-community/parakeet-tdt-0.6b-v3 (Parakeet-TDT 0.6B v3, MLX)",
            kind: .asr,
            files: [
                ModelFile(
                    urlString: "https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3/resolve/main/model.safetensors",
                    sha256: nil, // TODO: record after download
                    sizeBytes: 2_695_000_000, // ~2.51 GB (confirmed from HF file listing)
                    relativePath: "model.safetensors"
                ),
                ModelFile(
                    urlString: "https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3/resolve/main/config.json",
                    sha256: nil,
                    sizeBytes: 249_856, // ~244 KB
                    relativePath: "config.json"
                ),
                ModelFile(
                    urlString: "https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3/resolve/main/tokenizer.model",
                    sha256: nil,
                    sizeBytes: 369_664, // ~361 KB
                    relativePath: "tokenizer.model"
                ),
            ],
            license: "CC-BY-4.0"
        ),

        // MARK: ASR bake-off — Voxtral-Mini-4B-Realtime-2602
        // HF repo: mistralai/Voxtral-Mini-4B-Realtime-2602
        // IMPORTANT: Word timestamps NOT available through mlx-audio-swift v0.1.x.
        // See VoxtralEngine.swift module comment and research.md D1.
        // TODO: verify exact file listing — the manifest below uses best-guess filenames.
        // VERIFY: mistralai/Voxtral-Mini-4B-Realtime-2602 HF file tree.
        ModelSpec(
            key: "voxtral-mini-4b-realtime-2602",
            displayName: "mistralai/Voxtral-Mini-4B-Realtime-2602 (Voxtral Mini 4B, fp16)",
            kind: .asr,
            files: [
                ModelFile(
                    urlString: "https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602/resolve/main/model.safetensors",
                    sha256: nil,
                    sizeBytes: 8_900_000_000, // ~8.9 GB fp16 (from research.md Q2)
                    relativePath: "model.safetensors"
                ),
                ModelFile(
                    urlString: "https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602/resolve/main/config.json",
                    sha256: nil,
                    sizeBytes: nil, // VERIFY
                    relativePath: "config.json"
                ),
            ],
            license: "Apache-2.0"
        ),

        // MARK: Diarization — pyannote speaker-diarization-community-1 via FluidInference CoreML
        // HF repo: FluidInference/speaker-diarization-community-1 (GATED — CC-BY-4.0)
        // The repo is gated on HF; user must accept the CC-BY-4.0 license before download.
        // FluidAudio's prepareModels() handles the download internally; the manifest entry
        // here is for display/attribution only (ModelStore does not download this directly).
        // File URLs and sizes: VERIFY from https://huggingface.co/FluidInference/speaker-diarization-community-1/tree/main
        // after accepting the gated license.
        ModelSpec(
            key: "speaker-diarization-community-1",
            displayName: "FluidInference/speaker-diarization-community-1 (pyannote community-1, CoreML/ANE)",
            kind: .diarization,
            files: [
                // Placeholder — FluidAudio downloads and compiles these via prepareModels().
                // Do NOT attempt to download these via ModelDownloader; use FluidDiarizer.load().
                ModelFile(
                    urlString: "", // Managed by FluidAudio; not downloaded by ModelDownloader.
                    sha256: nil,
                    sizeBytes: nil, // VERIFY total size after gated download
                    relativePath: "config.json"
                ),
            ],
            license: "CC-BY-4.0"
        ),

        // MARK: Summarization — Qwen3-30B-A3B-Instruct-2507-MLX-8bit
        // HF repo: lmstudio-community/Qwen3-30B-A3B-Instruct-2507-MLX-8bit
        // Files verified from https://huggingface.co/lmstudio-community/Qwen3-30B-A3B-Instruct-2507-MLX-8bit/tree/main
        // Total: ~32.5 GB (7 × safetensors shards + tokenizer files)
        // TODO sha256: record after download.
        ModelSpec(
            key: "qwen3-30b-a3b-instruct-2507-mlx-8bit",
            displayName: "lmstudio-community/Qwen3-30B-A3B-Instruct-2507-MLX-8bit (Qwen3 30B MoE, 8-bit MLX)",
            kind: .llm,
            files: [
                // 7 safetensors shards (~5.2–5.3 GB each, final shard ~758 MB).
                // URLs verified from HF file listing 2026-06-18.
                ModelFile(
                    urlString: "https://huggingface.co/lmstudio-community/Qwen3-30B-A3B-Instruct-2507-MLX-8bit/resolve/main/model-00001-of-00007.safetensors",
                    sha256: nil,
                    sizeBytes: 5_584_000_000, // ~5.2 GB
                    relativePath: "model-00001-of-00007.safetensors"
                ),
                ModelFile(
                    urlString: "https://huggingface.co/lmstudio-community/Qwen3-30B-A3B-Instruct-2507-MLX-8bit/resolve/main/model-00002-of-00007.safetensors",
                    sha256: nil,
                    sizeBytes: 5_690_000_000, // ~5.3 GB
                    relativePath: "model-00002-of-00007.safetensors"
                ),
                ModelFile(
                    urlString: "https://huggingface.co/lmstudio-community/Qwen3-30B-A3B-Instruct-2507-MLX-8bit/resolve/main/model-00003-of-00007.safetensors",
                    sha256: nil,
                    sizeBytes: 5_690_000_000,
                    relativePath: "model-00003-of-00007.safetensors"
                ),
                ModelFile(
                    urlString: "https://huggingface.co/lmstudio-community/Qwen3-30B-A3B-Instruct-2507-MLX-8bit/resolve/main/model-00004-of-00007.safetensors",
                    sha256: nil,
                    sizeBytes: 5_690_000_000,
                    relativePath: "model-00004-of-00007.safetensors"
                ),
                ModelFile(
                    urlString: "https://huggingface.co/lmstudio-community/Qwen3-30B-A3B-Instruct-2507-MLX-8bit/resolve/main/model-00005-of-00007.safetensors",
                    sha256: nil,
                    sizeBytes: 5_690_000_000,
                    relativePath: "model-00005-of-00007.safetensors"
                ),
                ModelFile(
                    urlString: "https://huggingface.co/lmstudio-community/Qwen3-30B-A3B-Instruct-2507-MLX-8bit/resolve/main/model-00006-of-00007.safetensors",
                    sha256: nil,
                    sizeBytes: 5_690_000_000,
                    relativePath: "model-00006-of-00007.safetensors"
                ),
                ModelFile(
                    urlString: "https://huggingface.co/lmstudio-community/Qwen3-30B-A3B-Instruct-2507-MLX-8bit/resolve/main/model-00007-of-00007.safetensors",
                    sha256: nil,
                    sizeBytes: 795_000_000, // ~758 MB
                    relativePath: "model-00007-of-00007.safetensors"
                ),
                // Index + config files.
                ModelFile(
                    urlString: "https://huggingface.co/lmstudio-community/Qwen3-30B-A3B-Instruct-2507-MLX-8bit/resolve/main/model.safetensors.index.json",
                    sha256: nil,
                    sizeBytes: 122_880, // ~120 KB
                    relativePath: "model.safetensors.index.json"
                ),
                ModelFile(
                    urlString: "https://huggingface.co/lmstudio-community/Qwen3-30B-A3B-Instruct-2507-MLX-8bit/resolve/main/config.json",
                    sha256: nil,
                    sizeBytes: 1_218,
                    relativePath: "config.json"
                ),
                ModelFile(
                    urlString: "https://huggingface.co/lmstudio-community/Qwen3-30B-A3B-Instruct-2507-MLX-8bit/resolve/main/generation_config.json",
                    sha256: nil,
                    sizeBytes: 239,
                    relativePath: "generation_config.json"
                ),
                ModelFile(
                    urlString: "https://huggingface.co/lmstudio-community/Qwen3-30B-A3B-Instruct-2507-MLX-8bit/resolve/main/tokenizer.json",
                    sha256: nil,
                    sizeBytes: 11_956_224, // ~11.4 MB
                    relativePath: "tokenizer.json"
                ),
                ModelFile(
                    urlString: "https://huggingface.co/lmstudio-community/Qwen3-30B-A3B-Instruct-2507-MLX-8bit/resolve/main/tokenizer_config.json",
                    sha256: nil,
                    sizeBytes: 9_856, // ~9.6 KB
                    relativePath: "tokenizer_config.json"
                ),
                ModelFile(
                    urlString: "https://huggingface.co/lmstudio-community/Qwen3-30B-A3B-Instruct-2507-MLX-8bit/resolve/main/vocab.json",
                    sha256: nil,
                    sizeBytes: 2_916_352, // ~2.78 MB
                    relativePath: "vocab.json"
                ),
                ModelFile(
                    urlString: "https://huggingface.co/lmstudio-community/Qwen3-30B-A3B-Instruct-2507-MLX-8bit/resolve/main/merges.txt",
                    sha256: nil,
                    sizeBytes: 1_750_016, // ~1.67 MB
                    relativePath: "merges.txt"
                ),
            ],
            license: "Apache-2.0"
        ),
    ]
}
