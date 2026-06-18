// The AVAudioConverter input block is typed @Sendable by the SDK, but Apple's own
// documentation and implementation guarantee it is called synchronously on the calling
// thread. We route mutable capture state through a tiny reference-type box to satisfy
// Swift 6's Sendable checker without @unchecked Sendable on the broader types.

import AVFoundation
import Foundation

/// Resamples audio files and buffers from 48 kHz float32 mono → 16 kHz float32 mono,
/// the format required by Parakeet/Whisper/Voxtral ASR engines (plan.md ADR-1).
///
/// `AVAudioConverter` handles arbitrary ratio resampling in one pass; the 3:1 ratio
/// (48 k → 16 k) is exact and efficient on Apple Silicon.
// Box for synchronous callback state — avoids capturing `var` in a @Sendable closure.
private final class OnceBox<T: AnyObject>: @unchecked Sendable {
    // @unchecked Sendable: mutations occur only within the AVAudioConverter input block,
    // which Apple documents as called synchronously on the calling thread. The box is
    // never shared across threads.
    var value: T?
    init(_ value: T) { self.value = value }
}

private final class FlagBox: @unchecked Sendable {
    // Same rationale as OnceBox.
    var fired = false
}

public enum AudioResampler {
    // MARK: - Formats

    /// Native SCStream capture format.
    public static let sourceFormat: AVAudioFormat = {
        // Non-interleaved float32 mono @ 48 kHz.
        guard let f = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ) else { preconditionFailure("Failed to create 48 kHz source format") }
        return f
    }()

    /// ASR engine input format.
    public static let targetFormat: AVAudioFormat = {
        guard let f = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { preconditionFailure("Failed to create 16 kHz target format") }
        return f
    }()

    // MARK: - Buffer API

    /// Resample a single `AVAudioPCMBuffer` from any supported format to 16 kHz mono float32.
    ///
    /// - Parameters:
    ///   - buffer: Source buffer (must be float32 mono; rate may differ from 48 kHz).
    ///   - outputFormat: Target format (defaults to ``targetFormat``).
    /// - Returns: Resampled buffer.
    /// - Throws: `ResampleError` on converter creation failure or conversion failure.
    public static func resample(
        _ buffer: AVAudioPCMBuffer,
        to outputFormat: AVAudioFormat = targetFormat
    ) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw ResampleError.converterCreationFailed(from: inputFormat, to: outputFormat)
        }

        // Output frame count scales by the sample-rate ratio.
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            throw ResampleError.outputBufferAllocationFailed
        }

        let bufBox = OnceBox(buffer)
        let status = converter.convert(to: output, error: nil) { _, outStatus in
            guard let buf = bufBox.value else {
                outStatus.pointee = .noDataNow
                return nil
            }
            bufBox.value = nil
            outStatus.pointee = .haveData
            return buf
        }

        guard status != .error else { throw ResampleError.conversionFailed }
        return output
    }

    // MARK: - File API

    /// Read `input`, resample to 16 kHz float32 mono, write a WAV to `output`.
    ///
    /// Both paths must be file URLs. The output file is created or overwritten.
    /// This is the primary entry point for Stage-2 pre-processing (plan.md M2.1).
    ///
    /// - Parameters:
    ///   - input: Path to a WAV/CAF audio file (any sample rate, mono recommended).
    ///   - output: Destination path for the 16 kHz WAV.
    public static func resample(input: URL, output: URL) throws {
        let sourceFile = try AVAudioFile(forReading: input)
        let sourceFileFormat = sourceFile.processingFormat
        let totalFrames = AVAudioFrameCount(sourceFile.length)

        guard let converter = AVAudioConverter(from: sourceFileFormat, to: targetFormat) else {
            throw ResampleError.converterCreationFailed(from: sourceFileFormat, to: targetFormat)
        }

        // Read into memory in chunks to avoid peak memory for hour-long recordings.
        let chunkFrames: AVAudioFrameCount = 65_536
        let outChunkCapacity = AVAudioFrameCount(
            Double(chunkFrames) * targetFormat.sampleRate / sourceFileFormat.sampleRate + 1
        )

        let destFile = try AVAudioFile(
            forWriting: output,
            settings: targetFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        guard let inputBuf = AVAudioPCMBuffer(pcmFormat: sourceFileFormat, frameCapacity: chunkFrames),
              let outputBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outChunkCapacity)
        else { throw ResampleError.outputBufferAllocationFailed }

        var framesRead: AVAudioFrameCount = 0

        while framesRead < totalFrames {
            let remaining = totalFrames - framesRead
            let toRead = min(chunkFrames, remaining)
            inputBuf.frameLength = toRead
            try sourceFile.read(into: inputBuf, frameCount: toRead)
            framesRead += toRead

            let isFinalChunk = framesRead >= totalFrames
            let providerFlag = FlagBox()
            let chunkBox = OnceBox(inputBuf)

            let status = converter.convert(to: outputBuf, error: nil) { _, outStatus in
                guard !providerFlag.fired else {
                    outStatus.pointee = isFinalChunk ? .endOfStream : .noDataNow
                    return nil
                }
                providerFlag.fired = true
                outStatus.pointee = .haveData
                return chunkBox.value
            }

            if status == .error { throw ResampleError.conversionFailed }
            if outputBuf.frameLength > 0 {
                try destFile.write(from: outputBuf)
            }
        }
    }

    // MARK: - Errors

    public enum ResampleError: Error, Sendable {
        case converterCreationFailed(from: AVAudioFormat, to: AVAudioFormat)
        case outputBufferAllocationFailed
        case conversionFailed
    }
}
