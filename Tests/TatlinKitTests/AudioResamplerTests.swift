import AVFoundation
import Foundation
import Testing
@testable import TatlinKit

// MARK: - Helpers

/// Generate a mono float32 sine wave buffer at the given sample rate and frequency.
private func sineSamples(
    sampleRate: Double,
    frequency: Double = 440,
    durationSeconds: Double = 1.0
) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )!
    let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount

    let channel = buffer.floatChannelData![0]
    for i in 0..<Int(frameCount) {
        channel[i] = Float(sin(2 * Double.pi * frequency * Double(i) / sampleRate))
    }
    return buffer
}

/// Write a PCM buffer to a temp WAV file and return the URL.
private func writeWAV(_ buffer: AVAudioPCMBuffer) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tatlin-test-\(UUID().uuidString).wav")
    let file = try AVAudioFile(
        forWriting: url,
        settings: buffer.format.settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    try file.write(from: buffer)
    return url
}

// MARK: - Tests

@Suite("AudioResampler")
struct AudioResamplerTests {

    @Test("buffer API: output sample rate is 16 kHz")
    func bufferResampleRate() throws {
        let source = sineSamples(sampleRate: 48_000, durationSeconds: 0.5)
        let output = try AudioResampler.resample(source)
        #expect(output.format.sampleRate == 16_000)
    }

    @Test("buffer API: output channel count is 1")
    func bufferResampleChannels() throws {
        let source = sineSamples(sampleRate: 48_000, durationSeconds: 0.5)
        let output = try AudioResampler.resample(source)
        #expect(output.format.channelCount == 1)
    }

    @Test("buffer API: output frame count is approximately 1/3 of input")
    func bufferResampleFrameCount() throws {
        let source = sineSamples(sampleRate: 48_000, durationSeconds: 1.0)
        let output = try AudioResampler.resample(source)
        // 48k → 16k: exact 3:1 ratio; allow ±16 frames for converter look-ahead/rounding.
        let expected = source.frameLength / 3
        #expect(abs(Int(output.frameLength) - Int(expected)) <= 16)
    }

    @Test("buffer API: output format is float32")
    func bufferResampleFormat() throws {
        let source = sineSamples(sampleRate: 48_000, durationSeconds: 0.1)
        let output = try AudioResampler.resample(source)
        #expect(output.format.commonFormat == .pcmFormatFloat32)
    }

    @Test("file API: output file sample rate is 16 kHz")
    func fileResampleRate() throws {
        let source = sineSamples(sampleRate: 48_000, durationSeconds: 1.0)
        let inputURL = try writeWAV(source)
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tatlin-test-out-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        try AudioResampler.resample(input: inputURL, output: outputURL)

        let outFile = try AVAudioFile(forReading: outputURL)
        #expect(outFile.processingFormat.sampleRate == 16_000)
    }

    @Test("file API: output duration matches input duration")
    func fileResampleDuration() throws {
        let durationSeconds = 2.0
        let source = sineSamples(sampleRate: 48_000, durationSeconds: durationSeconds)
        let inputURL = try writeWAV(source)
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tatlin-test-dur-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        try AudioResampler.resample(input: inputURL, output: outputURL)

        let outFile = try AVAudioFile(forReading: outputURL)
        let outDuration = Double(outFile.length) / outFile.processingFormat.sampleRate
        // Allow 25 ms tolerance for converter look-ahead/tail-frame rounding.
        #expect(abs(outDuration - durationSeconds) < 0.025)
    }

    @Test("file API: output format is float32")
    func fileResampleFormatIsFloat32() throws {
        let source = sineSamples(sampleRate: 48_000, durationSeconds: 0.1)
        let inputURL = try writeWAV(source)
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tatlin-test-fmt-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        try AudioResampler.resample(input: inputURL, output: outputURL)

        let outFile = try AVAudioFile(forReading: outputURL)
        #expect(outFile.processingFormat.commonFormat == .pcmFormatFloat32)
    }
}
