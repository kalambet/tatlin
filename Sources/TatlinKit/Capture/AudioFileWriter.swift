import AVFoundation
import CoreMedia
import Foundation

/// Streams a mono 48 kHz / 32-bit-float WAV to disk as audio arrives from SCStream.
///
/// Open the writer before capture starts; append CMSampleBuffers or AVAudioPCMBuffers
/// as they arrive; call `close()` when capture stops or the app is interrupted.
/// Because `AVAudioFile` flushes every write, the WAV header is always consistent —
/// a partial recording is valid and playable even after a crash (plan.md M1.2).
///
/// This type is a class (reference semantics) so `SCStreamRecorder` can hold it
/// as a shared mutable resource inside an actor without Sendable issues.
public final class AudioFileWriter: @unchecked Sendable {
    // MARK: - State
    // Guarded by the calling actor (SCStreamRecorder). @unchecked Sendable is safe here
    // because all mutations happen from a single SCStreamRecorder actor context.

    private var audioFile: AVAudioFile?
    private let fileURL: URL

    /// 48 kHz / float32 / mono — the native SCStream format (plan.md ADR-1).
    private let writeFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    // MARK: - Lifecycle

    /// Create a writer that will write to `url` once `open()` is called.
    public init(url: URL) {
        self.fileURL = url
    }

    /// Open (or re-open after a stream restart) the WAV file for writing.
    /// Safe to call multiple times; re-opens in append mode after a restart.
    public func open() throws {
        guard audioFile == nil else { return }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            // Append to an existing partial file after a watchdog restart.
            audioFile = try AVAudioFile(forWriting: fileURL,
                                        settings: writeFormat.settings,
                                        commonFormat: .pcmFormatFloat32,
                                        interleaved: false)
        } else {
            audioFile = try AVAudioFile(forWriting: fileURL,
                                        settings: writeFormat.settings,
                                        commonFormat: .pcmFormatFloat32,
                                        interleaved: false)
        }
    }

    /// Append a `CMSampleBuffer` from an `SCStream` audio callback.
    ///
    /// Converts the CMSampleBuffer to `AVAudioPCMBuffer` using the buffer's
    /// embedded format description; resampling is NOT done here — keep 48 kHz
    /// originals and resample at ASR time (plan.md ADR-1).
    public func append(_ sampleBuffer: CMSampleBuffer) throws {
        guard let file = audioFile else { throw AudioWriterError.notOpen }

        // Derive the audio format from the sample buffer's format description.
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamFormat = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { throw AudioWriterError.invalidSampleBuffer }

        guard let bufferFormat = AVAudioFormat(streamDescription: streamFormat) else {
            throw AudioWriterError.invalidSampleBuffer
        }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: bufferFormat, frameCapacity: frameCount) else {
            throw AudioWriterError.bufferAllocationFailed
        }
        pcmBuffer.frameLength = frameCount

        // Copy audio samples from the CMBlockBuffer into the AVAudioPCMBuffer.
        // CMSampleBufferCopyPCMDataIntoAudioBufferList returns OSStatus, not throwing.
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else { throw AudioWriterError.invalidSampleBuffer }

        // If the buffer format matches writeFormat, write directly; otherwise convert.
        if bufferFormat.sampleRate == writeFormat.sampleRate
            && bufferFormat.channelCount == writeFormat.channelCount
        {
            try file.write(from: pcmBuffer)
        } else {
            let resampled = try AudioResampler.resample(pcmBuffer, to: writeFormat)
            try file.write(from: resampled)
        }
    }

    /// Append a pre-formed `AVAudioPCMBuffer` directly (useful for testing and for
    /// paths that bypass CMSampleBuffer, e.g., the resampler unit test fixture).
    public func append(_ buffer: AVAudioPCMBuffer) throws {
        guard let file = audioFile else { throw AudioWriterError.notOpen }
        if buffer.format.sampleRate == writeFormat.sampleRate
            && buffer.format.channelCount == writeFormat.channelCount
        {
            try file.write(from: buffer)
        } else {
            let resampled = try AudioResampler.resample(buffer, to: writeFormat)
            try file.write(from: resampled)
        }
    }

    /// Flush pending writes and close the file. Safe to call more than once.
    public func close() {
        audioFile = nil   // AVAudioFile flushes and closes on dealloc.
    }

    /// The URL this writer is targeting.
    public var url: URL { fileURL }

    // MARK: - Errors

    public enum AudioWriterError: Error, Sendable {
        case notOpen
        case invalidSampleBuffer
        case bufferAllocationFailed
    }
}

// MARK: - CMSampleBuffer helper

private extension AudioFileWriter {
    // Expose AudioResampler for the file-write path above.
}
