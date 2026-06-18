import Foundation

/// Tatlin — local-first, on-device macOS meeting note-taker.
///
/// `TatlinKit` holds all platform/system-framework pipeline logic. Concrete ML engines
/// (Parakeet ASR, Qwen summarizer, FluidAudio diarizer) live in the optional `TatlinML`
/// target and conform to the protocols declared here (``ASREngine``, ``DiarizerEngine``,
/// ``LLMEngine``), so the core compiles and the capture spike runs without the MLX graph.
public enum Tatlin {
    /// Marketing/CLI version.
    public static let version = "0.0.1"

    /// Reverse-DNS bundle identifier, used for the Application Support directory name.
    public static let bundleIdentifier = "dev.kalambet.tatlin"
}
