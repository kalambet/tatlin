// swift-tools-version: 6.0
import PackageDescription

// Tatlin — local-first, on-device macOS meeting note-taker.
//
// Target layout (see plan.md, Part B):
//   • TatlinKit  — all platform/system-framework pipeline logic (Phase 1 + 1B infra).
//                  Depends ONLY on system frameworks → builds & tests fast and offline.
//   • tatlin     — CLI harness (record / calendar / pipeline / eval subcommands).
//   • TatlinML   — concrete MLX/FluidAudio engine conformances (Parakeet, Qwen, FluidAudio).
//                  Pulls the heavy MLX/Metal transitive graph; needs on-device model weights
//                  to exercise. Commented out until enabled locally (see Sources/TatlinML/README.md).
//
// The ML stack is intentionally isolated behind the protocols in TatlinKit so the core
// compiles and the capture spike runs without resolving the MLX graph.

let package = Package(
    name: "Tatlin",
    platforms: [
        .macOS(.v15) // SCStream microphone capture requires macOS 15+; runtime host is macOS 26.
    ],
    products: [
        .library(name: "TatlinKit", targets: ["TatlinKit"]),
        .executable(name: "tatlin", targets: ["tatlin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),

        // --- Heavy ML stack (TatlinML target). mlx-audio-swift 0.1.2 pins mlx-swift-lm to
        //     2.30.3 ..< 3.0.0, so MLXLLM/MLXLMCommon come from mlx-swift-lm (NOT
        //     mlx-swift-examples) and must stay on the 2.x line. ---
        .package(url: "https://github.com/ml-explore/mlx-swift.git", .upToNextMajor(from: "0.30.6")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", .upToNextMajor(from: "2.30.3")),
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", from: "0.1.2"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.9.1"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "TatlinKit"
        ),
        .executableTarget(
            name: "tatlin",
            dependencies: [
                "TatlinKit",
                "TatlinML",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "TatlinKitTests",
            dependencies: ["TatlinKit"]
        ),

        // --- Concrete ML engines ---
        .target(
            name: "TatlinML",
            dependencies: [
                "TatlinKit",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
    ]
)
