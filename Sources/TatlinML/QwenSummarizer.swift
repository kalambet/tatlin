// QwenSummarizer.swift — TatlinML
//
// Concrete LLMEngine backed by Qwen3-30B-A3B-Instruct-2507-MLX-8bit via mlx-swift-lm.
//
// Source references:
//   Protocol contract:   Sources/TatlinKit/Summarization/MeetingNotes.swift
//   ModelConfiguration (id: String init):
//     https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/ModelConfiguration.swift
//   ModelContainer (generate, perform):
//     https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/ModelContainer.swift
//   Chat.Message (system, user, assistant roles):
//     https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/Chat.swift
//   ChatSession (respond(to:) / streamResponse):
//     https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/ChatSession.swift
//   GenerateParameters (temperature, topP, maxTokens):
//     https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/Evaluate.swift
//   UserInput (prompt: / chat:):
//     https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/UserInput.swift
//   loadModelContainer (from downloader, id: String):
//     https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/ModelFactory.swift
//   Package URL:  https://github.com/ml-explore/mlx-swift-lm  (product: MLXLLM, MLXLMCommon)
//   NOTE: As of v3.31.3 MLXLLM/MLXLMCommon live in mlx-swift-lm, NOT mlx-swift-examples.
//         Update Package.swift deps accordingly (see Sources/TatlinML/README.md).
//
// Qwen3MoE loader is confirmed working in mlx-swift-lm; Qwen3-30B-A3B variants use
// the Qwen3MoE.swift architecture file.
// Research backing: research.md Q6, plan.md ADR-6.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import TatlinKit

/// LLM engine that loads Qwen3-30B-A3B-Instruct-2507-MLX-8bit from a pre-downloaded
/// directory and runs chat completions via `mlx-swift-lm`.
///
/// **Memory:** ~32 GB weights + 3–6 GB KV at 8-bit.  Only load this engine after ASR and
/// diarization are released (ModelHost sequential residency — plan.md ADR-11).
///
/// **Generation approach:** We use `ChatSession.respond(to:)` for single-turn completions
/// (meeting notes are always one-shot), passing `GenerateParameters` for temp/topP/maxTokens.
/// For the streaming eval harness use `streamResponse(to:)` instead.
///
/// **No constrained decoding:** mlx-swift-lm v3.x has no JSON grammar support (issue #221).
/// All structure is prompt-driven; `NotesParser` in TatlinKit validates / repairs the output.
///
/// VERIFY items are marked inline; verify against the compiled `.swiftmodule` when TatlinML
/// is first enabled on device.
@available(macOS 15, *)
public actor QwenSummarizer: LLMEngine {

    // MARK: - LLMEngine

    public nonisolated let modelID = "qwen3-30b-a3b-instruct-2507-mlx-8bit"

    // MARK: - Private state

    private var container: ModelContainer?
    private let modelDirectory: URL

    // MARK: - Init

    /// - Parameter modelDirectory: Directory containing the Qwen3 MoE weights + tokenizer.
    ///   ModelStore downloads and verifies these before `load()` is called.
    public init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    // MARK: - Load / unload

    /// Load the Qwen3-30B MoE model from `modelDirectory`.
    ///
    /// `loadModelContainer` is the mlx-swift-lm factory that reads `config.json`,
    /// selects the `Qwen3MoE` architecture, and loads weights from `.safetensors` shards.
    ///
    /// VERIFY: `loadModelContainer(configuration:)` signature with a `ModelConfiguration`
    /// pointing at a local directory.  The `.directory(URL)` Identifier variant should work.
    /// Source: https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/ModelFactory.swift
    ///         https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/ModelConfiguration.swift
    public func load() async throws {
        guard container == nil else { return }

        // ModelConfiguration with a local directory path.
        // Identifier.directory(URL) bypasses HuggingFace download.
        // Source: https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/ModelConfiguration.swift
        let config = ModelConfiguration(directory: modelDirectory)

        // VERIFY: `LLMModelFactory.shared.loadContainer(configuration:)` is the right
        // entry-point for local-directory loading in v3.31.3.
        // Alternative: `loadModelContainer(configuration:)` free function if one exists.
        // Source: https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLLM/LLMModelFactory.swift
        container = try await LLMModelFactory.shared.loadContainer(configuration: config)
    }

    public func unload() {
        container = nil
        // Drop KV cache and weight cache.
        // VERIFY: MLX.GPU.clearCache() API name.
        // Source: https://github.com/ml-explore/mlx-swift (GPU.swift)
        MLX.GPU.clearCache()
    }

    // MARK: - LLMEngine conformance

    /// Run a single-turn chat completion and return the full assistant text.
    ///
    /// - Parameters:
    ///   - messages: Ordered system / user / assistant turns from `SummaryPrompt`.
    ///   - parameters: Sampling settings (temp, topP, maxTokens) from `LLMParameters`.
    /// - Returns: Raw assistant text; `NotesParser` in TatlinKit validates the structure.
    public func complete(messages: [LLMMessage], parameters: LLMParameters) async throws -> String {
        guard let container else {
            throw LLMError.modelNotLoaded
        }

        // Map TatlinKit LLMMessage → mlx-swift-lm Chat.Message.
        // Chat.Message factory methods:
        //   .system(_:)    — for Role.system
        //   .user(_:)      — for Role.user
        //   .assistant(_:) — for Role.assistant
        // Source: https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/Chat.swift
        let chatMessages: [Chat.Message] = messages.map { msg in
            switch msg.role {
            case .system:    return .system(msg.content)
            case .user:      return .user(msg.content)
            case .assistant: return .assistant(msg.content)
            }
        }

        // Build GenerateParameters.
        // Confirmed fields from Evaluate.swift inspection:
        //   temperature: Float, topP: Float, maxTokens: Int?
        // Source: https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/Evaluate.swift
        let genParams = GenerateParameters(
            temperature: Float(parameters.temperature),
            topP: Float(parameters.topP),
            maxTokens: parameters.maxTokens
        )

        // Use ChatSession for single-turn completion.
        // ChatSession.init(_ model:) — takes ModelContainer.
        // ChatSession.respond(to messages:[Chat.Message]) async throws -> String
        // Source: https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/ChatSession.swift
        //
        // VERIFY: The `respond(to:)` overload accepting [Chat.Message] exists and passes
        // generateParameters.  If only a String overload exists, build a single user-turn
        // string from the message array instead.
        let session = ChatSession(container, generateParameters: genParams)
        let response: String = try await session.respond(to: chatMessages)

        return response
    }
}

// MARK: - Errors

public enum LLMError: Error, Sendable {
    case modelNotLoaded
    case generationFailed(String)
}
