import Testing
import Foundation
import AVFoundation
@testable import AmendCore

@Suite("Loudness Normalizer Tests")
final class LoudnessNormalizerTests {
    private let normalizer = LoudnessNormalizer()

    private func makeSineBuffer(frequency: Float = 1000.0, amplitude: Float = 0.5, sampleRate: Double = 48000.0, durationSeconds: Double = 1.0) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let data = buffer.floatChannelData![0]

        for i in 0..<Int(frameCount) {
            data[i] = amplitude * sin(2.0 * Float.pi * frequency * Float(i) / Float(sampleRate))
        }
        return buffer
    }

    @Test("RMS measurement calculates accurate dBFS for sine wave")
    func test_rms_measurement() throws {
        // A sine wave of amplitude 0.5 has theoretical RMS = 0.5 / sqrt(2) ≈ 0.35355
        // 20 * log10(0.35355) ≈ -9.03 dBFS
        let buffer = makeSineBuffer(amplitude: 0.5)
        let rmsDBFS = try normalizer.measureRMS(buffer: buffer)

        #expect(abs(rmsDBFS - (-9.03)) < 0.1)
    }

    @Test("LUFS measurement calculates BS.1770-4 K-weighted loudness")
    func test_lufs_measurement() throws {
        let buffer = makeSineBuffer(frequency: 1000.0, amplitude: 0.5)
        let lufs = try normalizer.measureLUFS(buffer: buffer)

        // The 1kHz sine wave at amplitude 0.5 undergoes K-weighting high-shelf boost
        // and -0.691 offset. It should be a reasonable negative LUFS value (-10 to -7 LUFS)
        #expect(lufs < 0.0)
        #expect(lufs > -20.0)
    }

    @Test("Peak measurement detects maximum absolute amplitude")
    func test_peak_measurement() throws {
        let buffer = makeSineBuffer(amplitude: 0.72)
        let peak = try normalizer.measurePeak(buffer: buffer)

        #expect(abs(peak - 0.72) < 0.01)
    }

    @Test("Normalization adjusts gain and strictly respects peak ceiling")
    func test_normalization_peak_ceiling() throws {
        let buffer = makeSineBuffer(frequency: 440.0, amplitude: 0.5)

        // Request an aggressive target of 0.0 LUFS which would exceed the ceiling without limiting
        let (normalized, appliedGainDB) = try normalizer.normalize(
            buffer: buffer,
            targetLUFS: 0.0,
            peakCeiling: 0.95
        )

        let outputPeak = try normalizer.measurePeak(buffer: normalized)
        #expect(outputPeak <= 0.9501)
        #expect(appliedGainDB > 0.0)
    }

    @Test("Match loudness adjusts source buffer to reference buffer loudness")
    func test_match_loudness() throws {
        let quietSource = makeSineBuffer(frequency: 1000.0, amplitude: 0.1) // Quiet
        let loudReference = makeSineBuffer(frequency: 1000.0, amplitude: 0.5) // Louder

        let (matched, appliedGainDB) = try normalizer.matchLoudness(
            sourceBuffer: quietSource,
            referenceBuffer: loudReference
        )

        let matchedLUFS = try normalizer.measureLUFS(buffer: matched)
        let refLUFS = try normalizer.measureLUFS(buffer: loudReference)

        #expect(abs(matchedLUFS - refLUFS) < 0.5)
        #expect(appliedGainDB > 0.0)
    }

    @Test("Empty buffer throws error on measurement")
    func test_empty_buffer_throws() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
        buffer.frameLength = 0

        #expect(throws: LoudnessNormalizerError.self) {
            try normalizer.measureRMS(buffer: buffer)
        }
        #expect(throws: LoudnessNormalizerError.self) {
            try normalizer.measureLUFS(buffer: buffer)
        }
    }
}
