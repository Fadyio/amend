import Testing
import Foundation
import AVFoundation
import Accelerate
@testable import MacDubCore

@Suite("DSP Adversarial & Audio Math Challenge Tests")
final class DSPAdversarialTests {
    private let crossfader = BoundaryCrossfader()
    private let normalizer = LoudnessNormalizer()

    // MARK: - Helper Methods

    private func makeSineBuffer(
        frequency: Float = 1000.0,
        amplitude: Float = 0.5,
        sampleRate: Double = 48000.0,
        durationSeconds: Double = 1.0,
        channels: Int = 1
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        for ch in 0..<channels {
            let data = buffer.floatChannelData![ch]
            for i in 0..<Int(frameCount) {
                data[i] = amplitude * sin(2.0 * Float.pi * frequency * Float(i) / Float(sampleRate))
            }
        }
        return buffer
    }

    private func makeSilentBuffer(
        sampleRate: Double = 48000.0,
        frameCount: AVAudioFrameCount = 48000,
        channels: Int = 1
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        for ch in 0..<channels {
            let data = buffer.floatChannelData![ch]
            memset(data, 0, Int(frameCount) * MemoryLayout<Float>.size)
        }
        return buffer
    }

    private func makeSquareWaveBuffer(
        frequency: Float = 1000.0,
        amplitude: Float = 1.0,
        sampleRate: Double = 48000.0,
        durationSeconds: Double = 0.1
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let data = buffer.floatChannelData![0]
        let period = Int(sampleRate / Double(frequency))

        for i in 0..<Int(frameCount) {
            let phase = i % period
            data[i] = phase < (period / 2) ? amplitude : -amplitude
        }
        return buffer
    }

    // MARK: - 1. Peak Ceiling & Clipping Prevention

    @Test("Peak ceiling strictly prevents clipping on 0 dBFS full-scale sine input")
    func test_normalize_full_scale_sine_strictly_obeys_ceiling() throws {
        // Full scale 0 dBFS sine wave (amplitude 1.0)
        let buffer = makeSineBuffer(frequency: 1000.0, amplitude: 1.0, durationSeconds: 0.5)

        // Request aggressive positive target LUFS
        let (normalized, _) = try normalizer.normalize(
            buffer: buffer,
            targetLUFS: +10.0,
            peakCeiling: 0.95
        )

        let peak = try normalizer.measurePeak(buffer: normalized)
        #expect(peak <= 0.95001, "Normalized peak \(peak) must never exceed ceiling 0.95")

        // Inspect every individual sample across all frames
        let data = normalized.floatChannelData![0]
        for i in 0..<Int(normalized.frameLength) {
            #expect(abs(data[i]) <= 0.95001, "Sample at index \(i) exceeded peak ceiling: \(data[i])")
        }
    }

    @Test("Peak ceiling strictly prevents clipping on full-scale square wave")
    func test_normalize_full_scale_square_wave() throws {
        let buffer = makeSquareWaveBuffer(amplitude: 1.0)

        let (normalized, _) = try normalizer.normalize(
            buffer: buffer,
            targetLUFS: 0.0,
            peakCeiling: 0.95
        )

        let peak = try normalizer.measurePeak(buffer: normalized)
        #expect(peak <= 0.95001, "Normalized square wave peak \(peak) must not exceed ceiling 0.95")
    }

    @Test("Peak ceiling handles overscaled signals (> 0 dBFS, amplitude 3.0)")
    func test_normalize_overscaled_signal() throws {
        let buffer = makeSineBuffer(frequency: 440.0, amplitude: 3.0, durationSeconds: 0.2)

        let (normalized, appliedGainDB) = try normalizer.normalize(
            buffer: buffer,
            targetLUFS: -14.0,
            peakCeiling: 0.95
        )

        let peak = try normalizer.measurePeak(buffer: normalized)
        #expect(peak <= 0.95001, "Peak of overscaled signal after normalization must not exceed 0.95")
        #expect(appliedGainDB < 0.0, "Applied gain must attenuate overscaled input")
    }

    @Test("Normalization respects custom peak ceilings (0.95, 0.50, 0.25, 0.10)")
    func test_normalize_custom_ceilings() throws {
        let buffer = makeSineBuffer(frequency: 1000.0, amplitude: 0.8, durationSeconds: 0.2)
        let ceilings: [Float] = [0.95, 0.50, 0.25, 0.10]

        for ceiling in ceilings {
            let (normalized, _) = try normalizer.normalize(
                buffer: buffer,
                targetLUFS: +20.0, // High target forcing ceiling limiter to engage
                peakCeiling: ceiling
            )
            let peak = try normalizer.measurePeak(buffer: normalized)
            #expect(peak <= ceiling + 0.001, "Output peak \(peak) must respect custom ceiling \(ceiling)")
        }
    }

    @Test("Extreme positive target LUFS (+100 dBFS) does not exceed ceiling")
    func test_normalize_extreme_positive_target() throws {
        let buffer = makeSineBuffer(frequency: 1000.0, amplitude: 0.5, durationSeconds: 0.2)

        let (normalized, appliedGainDB) = try normalizer.normalize(
            buffer: buffer,
            targetLUFS: +100.0,
            peakCeiling: 0.95
        )

        let peak = try normalizer.measurePeak(buffer: normalized)
        #expect(peak <= 0.95001)
        // Gain must be clamped to ceiling / inputPeak = 0.95 / 0.5 = 1.9 -> ~5.575 dB
        #expect(abs(appliedGainDB - 20.0 * log10(0.95 / 0.5)) < 0.1)
    }

    @Test("Extreme negative target LUFS (-100 dBFS) attenuates smoothly")
    func test_normalize_extreme_negative_target() throws {
        let buffer = makeSineBuffer(frequency: 1000.0, amplitude: 0.5, durationSeconds: 0.2)

        let (normalized, appliedGainDB) = try normalizer.normalize(
            buffer: buffer,
            targetLUFS: -100.0,
            peakCeiling: 0.95
        )

        let peak = try normalizer.measurePeak(buffer: normalized)
        #expect(peak < 0.0001, "Output should be near silence")
        #expect(appliedGainDB < -80.0)
    }

    // MARK: - 2. Silent and Zero-Amplitude Buffers

    @Test("Silent buffer RMS measurement returns clamping floor (-180 dBFS)")
    func test_measureRMS_silent_buffer() throws {
        let silent = makeSilentBuffer()
        let rms = try normalizer.measureRMS(buffer: silent)
        #expect(rms == -180.0, "Silent buffer RMS must equal -180.0 dBFS floor (20*log10(1e-9))")
        #expect(!rms.isNaN)
        #expect(!rms.isInfinite)
    }

    @Test("Silent buffer LUFS measurement returns clamping floor (-120.691 LUFS)")
    func test_measureLUFS_silent_buffer() throws {
        let silent = makeSilentBuffer()
        let lufs = try normalizer.measureLUFS(buffer: silent)
        #expect(abs(lufs - (-120.691)) < 0.01, "Silent buffer LUFS must equal -120.691 LUFS floor")
        #expect(!lufs.isNaN)
        #expect(!lufs.isInfinite)
    }

    @Test("Silent buffer normalization produces all zeros without error")
    func test_normalize_silent_buffer() throws {
        let silent = makeSilentBuffer(frameCount: 4800)
        let (normalized, _) = try normalizer.normalize(buffer: silent, targetLUFS: -16.0)

        let peak = try normalizer.measurePeak(buffer: normalized)
        #expect(peak == 0.0, "Normalizing silence must result in silence")
        #expect(normalized.frameLength == silent.frameLength)
    }

    @Test("Boundary crossfader applyBoundaryFades on silent buffer remains all zeros")
    func test_boundary_fades_on_silent_buffer() throws {
        let silent = makeSilentBuffer(frameCount: 4800)
        try crossfader.applyBoundaryFades(to: silent, windowDuration: 0.015, curve: .equalPower)

        let peak = try normalizer.measurePeak(buffer: silent)
        #expect(peak == 0.0)
    }

    @Test("Crossfading two silent buffers produces a silent buffer of correct length")
    func test_crossfade_two_silent_buffers() throws {
        let silentA = makeSilentBuffer(frameCount: 2400)
        let silentB = makeSilentBuffer(frameCount: 2400)

        let combined = try crossfader.crossfade(
            bufferA: silentA,
            bufferB: silentB,
            windowDuration: 0.015,
            curve: .equalPower
        )

        let expectedLength = 2400 + 2400 - Int((0.015 * 48000.0).rounded())
        #expect(Int(combined.frameLength) == expectedLength)
        let peak = try normalizer.measurePeak(buffer: combined)
        #expect(peak == 0.0)
    }

    // MARK: - 3. Single-Sample and Buffer Boundary Conditions

    @Test("Single-sample buffer handled safely by BoundaryCrossfader")
    func test_single_sample_boundary_fades() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = 0.75

        // Must not crash, divide-by-zero, or throw out-of-bounds error
        try crossfader.applyBoundaryFades(to: buffer, windowDuration: 0.015, curve: .equalPower)
        #expect(!buffer.floatChannelData![0][0].isNaN)
    }

    @Test("Single-sample buffer crossfade combines cleanly without crash")
    func test_single_sample_crossfade() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let bufA = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        let bufB = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        bufA.frameLength = 1
        bufB.frameLength = 1
        bufA.floatChannelData![0][0] = 0.5
        bufB.floatChannelData![0][0] = 0.5

        let combined = try crossfader.crossfade(bufferA: bufA, bufferB: bufB, windowDuration: 0.015)
        // fadeLength = min(fadeLength, min(1, 1)) = 1
        // totalLength = 1 + 1 - 1 = 1
        #expect(combined.frameLength == 1)
        #expect(!combined.floatChannelData![0][0].isNaN)
    }

    @Test("Single-sample buffer loudness measurement and normalization")
    func test_single_sample_loudness_normalization() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = 0.6

        let rms = try normalizer.measureRMS(buffer: buffer)
        #expect(!rms.isNaN)
        #expect(!rms.isInfinite)

        let peak = try normalizer.measurePeak(buffer: buffer)
        #expect(abs(peak - 0.6) < 0.0001)

        let lufs = try normalizer.measureLUFS(buffer: buffer)
        #expect(!lufs.isNaN)
        #expect(!lufs.isInfinite)

        let (normalized, _) = try normalizer.normalize(buffer: buffer, targetLUFS: -16.0, peakCeiling: 0.95)
        #expect(normalized.frameLength == 1)
        let outPeak = try normalizer.measurePeak(buffer: normalized)
        #expect(outPeak <= 0.95001)
    }

    @Test("Zero-frame buffer error handling in LoudnessNormalizer")
    func test_zero_frame_buffer_throws() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
        buffer.frameLength = 0

        #expect(throws: LoudnessNormalizerError.emptyBuffer) {
            try normalizer.measureRMS(buffer: buffer)
        }
        #expect(throws: LoudnessNormalizerError.emptyBuffer) {
            try normalizer.measureLUFS(buffer: buffer)
        }
        #expect(try normalizer.measurePeak(buffer: buffer) == 0.0)
    }

    // MARK: - 4. Near-Nyquist and High-Frequency Signals

    @Test("Near-Nyquist frequency signal remains numerically stable")
    func test_near_nyquist_stability() throws {
        let sampleRate = 48000.0
        let nyquistMinusOne: Float = Float(sampleRate / 2.0) - 1.0 // 23999 Hz
        let buffer = makeSineBuffer(frequency: nyquistMinusOne, amplitude: 0.8, sampleRate: sampleRate, durationSeconds: 0.1)

        let rms = try normalizer.measureRMS(buffer: buffer)
        #expect(!rms.isNaN)
        #expect(!rms.isInfinite)

        let lufs = try normalizer.measureLUFS(buffer: buffer)
        #expect(!lufs.isNaN)
        #expect(!lufs.isInfinite)

        let (normalized, _) = try normalizer.normalize(buffer: buffer, targetLUFS: -16.0, peakCeiling: 0.95)
        let peak = try normalizer.measurePeak(buffer: normalized)
        #expect(peak <= 0.95001)
        #expect(!peak.isNaN)
    }

    @Test("Alternating Nyquist impulse (+1, -1, +1, -1) does not destabilize K-weighting IIR filter")
    func test_alternating_nyquist_impulse() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let frameCount: AVAudioFrameCount = 4800
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let data = buffer.floatChannelData![0]

        for i in 0..<Int(frameCount) {
            data[i] = (i % 2 == 0) ? 1.0 : -1.0
        }

        let lufs = try normalizer.measureLUFS(buffer: buffer)
        #expect(!lufs.isNaN, "K-weighting IIR filter must not generate NaN on alternating Nyquist signal")
        #expect(!lufs.isInfinite, "K-weighting IIR filter must not blow up to Infinity")

        let (normalized, _) = try normalizer.normalize(buffer: buffer, targetLUFS: -20.0, peakCeiling: 0.95)
        let peak = try normalizer.measurePeak(buffer: normalized)
        #expect(peak <= 0.95001)
    }

    // MARK: - 5. Equal-Power Energy Conservation Across Window Durations

    @Test("Equal-power mathematical identity cos^2(theta) + sin^2(theta) == 1.0 at every sample step")
    func test_equal_power_identity_conservation() {
        let windowDurations: [TimeInterval] = [0.005, 0.010, 0.015, 0.020, 0.050]
        let sampleRate = 48000.0

        for duration in windowDurations {
            let fadeLength = Int((duration * sampleRate).rounded())
            let denom = Float(max(1, fadeLength - 1))

            for i in 0..<fadeLength {
                let theta = (Float.pi / 2.0) * (Float(i) / denom)
                let wA = cos(theta)
                let wB = sin(theta)
                let powerSum = (wA * wA) + (wB * wB)
                #expect(abs(powerSum - 1.0) < 1e-5, "Sum of squared weights must equal 1.0 at sample \(i) for window \(duration)s")
            }
        }
    }

    @Test("Equal-power crossfade conserves acoustic RMS energy across transition for uncorrelated noise")
    func test_equal_power_uncorrelated_noise_energy() throws {
        let sampleRate = 48000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frameCount: AVAudioFrameCount = 48000 // 1.0s each

        guard let bufA = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let bufB = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            Issue.record("Failed to allocate buffers")
            return
        }
        bufA.frameLength = frameCount
        bufB.frameLength = frameCount

        // Generate independent pseudo-random noise with uniform variance
        var seedA: UInt64 = 1234567
        var seedB: UInt64 = 7654321
        func lcg(seed: inout UInt64) -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let val = Float((seed >> 32) & 0xFFFFFFFF) / Float(0xFFFFFFFF)
            return (val * 2.0 - 1.0) * 0.5 // range [-0.5, 0.5]
        }

        let ptrA = bufA.floatChannelData![0]
        let ptrB = bufB.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            ptrA[i] = lcg(seed: &seedA)
            ptrB[i] = lcg(seed: &seedB)
        }

        let windowDurations: [TimeInterval] = [0.010, 0.015, 0.020]

        for windowDuration in windowDurations {
            let combined = try crossfader.crossfade(
                bufferA: bufA,
                bufferB: bufB,
                windowDuration: windowDuration,
                curve: .equalPower
            )

            let fadeLength = Int((windowDuration * sampleRate).rounded())
            let overlapStart = Int(frameCount) - fadeLength
            let outData = combined.floatChannelData![0]

            // Calculate RMS of pure Buffer A region
            var rmsA: Float = 0.0
            vDSP_rmsqv(ptrA, 1, &rmsA, vDSP_Length(fadeLength))

            // Calculate RMS in crossfaded overlap region
            var rmsOverlap: Float = 0.0
            vDSP_rmsqv(outData + overlapStart, 1, &rmsOverlap, vDSP_Length(fadeLength))

            // Calculate RMS of pure Buffer B region
            var rmsB: Float = 0.0
            vDSP_rmsqv(ptrB + fadeLength, 1, &rmsB, vDSP_Length(fadeLength))

            let dbA = 20.0 * log10(Double(rmsA))
            let dbOverlap = 20.0 * log10(Double(rmsOverlap))
            let dbB = 20.0 * log10(Double(rmsB))

            // Overlap RMS must match A and B within statistical tolerance (0.8 dB)
            #expect(abs(dbOverlap - dbA) < 0.8, "Equal-power crossfade RMS (\(dbOverlap) dB) should match Buffer A RMS (\(dbA) dB)")
            #expect(abs(dbOverlap - dbB) < 0.8, "Equal-power crossfade RMS (\(dbOverlap) dB) should match Buffer B RMS (\(dbB) dB)")
        }
    }

    @Test("Linear crossfade displays expected 3 dB power dip at midpoint for uncorrelated noise")
    func test_linear_crossfade_power_dip() throws {
        let sampleRate = 48000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frameCount: AVAudioFrameCount = 24000

        let bufA = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        let bufB = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        bufA.frameLength = frameCount
        bufB.frameLength = frameCount

        var seedA: UInt64 = 1111111
        var seedB: UInt64 = 9999999
        func lcg(seed: inout UInt64) -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let val = Float((seed >> 32) & 0xFFFFFFFF) / Float(0xFFFFFFFF)
            return (val * 2.0 - 1.0) * 0.5
        }

        let ptrA = bufA.floatChannelData![0]
        let ptrB = bufB.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            ptrA[i] = lcg(seed: &seedA)
            ptrB[i] = lcg(seed: &seedB)
        }

        let combined = try crossfader.crossfade(
            bufferA: bufA,
            bufferB: bufB,
            windowDuration: 0.020,
            curve: .linear
        )

        let fadeLength = Int((0.020 * sampleRate).rounded())
        let overlapStart = Int(frameCount) - fadeLength
        let midIndex = overlapStart + (fadeLength / 2)

        // Measure RMS at the center of the linear crossfade (50 samples around center)
        var rmsCenter: Float = 0.0
        vDSP_rmsqv(combined.floatChannelData![0] + (midIndex - 25), 1, &rmsCenter, 50)

        var rmsA: Float = 0.0
        vDSP_rmsqv(ptrA, 1, &rmsA, 50)

        let dipDB = 20.0 * log10(Double(rmsCenter) / Double(rmsA))
        // Theoretical dip at linear midpoint: (0.5)^2 + (0.5)^2 = 0.5 -> -3.01 dB
        #expect(dipDB < -1.5, "Linear crossfade must exhibit power dip at midpoint (measured: \(dipDB) dB)")
    }

    // MARK: - 6. Multi-Channel Audio (Mono vs Stereo vs 5.1 Surround)

    @Test("Stereo panning balance is strictly preserved after normalization")
    func test_stereo_balance_preservation() throws {
        let sampleRate = 48000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let frameCount: AVAudioFrameCount = 4800
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        let leftData = buffer.floatChannelData![0]
        let rightData = buffer.floatChannelData![1]

        // Left channel has amplitude 0.8, Right channel has amplitude 0.2 (4:1 ratio = 12.04 dB difference)
        for i in 0..<Int(frameCount) {
            leftData[i] = 0.8 * sin(2.0 * Float.pi * 1000.0 * Float(i) / Float(sampleRate))
            rightData[i] = 0.2 * sin(2.0 * Float.pi * 1000.0 * Float(i) / Float(sampleRate))
        }

        let initialRatio = leftData[10] / rightData[10] // should be 4.0

        let (normalized, appliedGainDB) = try normalizer.normalize(
            buffer: buffer,
            targetLUFS: 0.0, // force ceiling limiter to trigger based on Left channel peak
            peakCeiling: 0.95
        )

        let outLeft = normalized.floatChannelData![0]
        let outRight = normalized.floatChannelData![1]
        let normalizedRatio = outLeft[10] / outRight[10]

        // Panning ratio must be identical
        #expect(abs(normalizedRatio - initialRatio) < 1e-4, "Stereo panning ratio must be preserved exactly")

        // Peak across ALL channels must respect ceiling (dominated by Left channel)
        let peak = try normalizer.measurePeak(buffer: normalized)
        #expect(peak <= 0.95001)

        // Gain was clamped by left channel: 0.95 / 0.8 ≈ 1.1875 (~1.49 dB)
        #expect(abs(appliedGainDB - 20.0 * log10(0.95 / 0.8)) < 0.1)
    }

    @Test("5.1 surround sound (6 channels) boundary crossfading")
    func test_multichannel_5_1_crossfade() throws {
        let sampleRate = 48000.0
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_AudioUnit_5_1)!
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
        let frameCountA: AVAudioFrameCount = 4800
        let frameCountB: AVAudioFrameCount = 4800

        let bufA = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCountA)!
        let bufB = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCountB)!
        bufA.frameLength = frameCountA
        bufB.frameLength = frameCountB

        // Fill each channel with a distinct DC level
        for ch in 0..<6 {
            let valA = Float(ch + 1) * 0.1 // 0.1, 0.2, 0.3, 0.4, 0.5, 0.6
            let valB = Float(6 - ch) * 0.1 // 0.6, 0.5, 0.4, 0.3, 0.2, 0.1
            for i in 0..<Int(frameCountA) { bufA.floatChannelData![ch][i] = valA }
            for i in 0..<Int(frameCountB) { bufB.floatChannelData![ch][i] = valB }
        }

        let combined = try crossfader.crossfade(
            bufferA: bufA,
            bufferB: bufB,
            windowDuration: 0.015,
            curve: .equalPower
        )

        #expect(combined.format.channelCount == 6)
        let fadeLength = Int((0.015 * sampleRate).rounded())
        let expectedLength = Int(frameCountA + frameCountB) - fadeLength
        #expect(Int(combined.frameLength) == expectedLength)

        // Verify each channel transitioned smoothly and has correct prefix/suffix
        for ch in 0..<6 {
            let outPtr = combined.floatChannelData![ch]
            let valA = Float(ch + 1) * 0.1
            let valB = Float(6 - ch) * 0.1

            // Prefix sample
            #expect(abs(outPtr[0] - valA) < 1e-4)
            // Suffix sample
            #expect(abs(outPtr[expectedLength - 1] - valB) < 1e-4)
        }
    }

    @Test("5.1 surround sound (6 channels) loudness normalization")
    func test_multichannel_5_1_normalization() throws {
        let sampleRate = 48000.0
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_AudioUnit_5_1)!
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
        let frameCount: AVAudioFrameCount = 4800
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        for ch in 0..<6 {
            let data = buffer.floatChannelData![ch]
            let amp = Float(ch + 1) * 0.15 // ch 5 has amp 0.9
            for i in 0..<Int(frameCount) {
                data[i] = amp * sin(2.0 * Float.pi * 1000.0 * Float(i) / Float(sampleRate))
            }
        }

        let rms = try normalizer.measureRMS(buffer: buffer)
        #expect(!rms.isNaN)

        let lufs = try normalizer.measureLUFS(buffer: buffer)
        #expect(!lufs.isNaN)

        let (normalized, appliedGainDB) = try normalizer.normalize(
            buffer: buffer,
            targetLUFS: 0.0,
            peakCeiling: 0.95
        )

        #expect(normalized.format.channelCount == 6)
        let peak = try normalizer.measurePeak(buffer: normalized)
        #expect(peak <= 0.95001, "Multi-channel normalized peak \(peak) must respect ceiling 0.95")
        // Clamped by max channel (ch 5, amp 0.9): gain = 0.95 / 0.9 ≈ 1.055
        #expect(appliedGainDB > 0.0)
    }

    // MARK: - 7. Subnormal and Denormalized Float Handling

    @Test("Denormalized / subnormal floats do not crash or hang normalizer")
    func test_subnormal_floats_handling() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let frameCount: AVAudioFrameCount = 1000
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let data = buffer.floatChannelData![0]

        // Fill with smallest positive nonzero subnormal float
        for i in 0..<Int(frameCount) {
            data[i] = Float.leastNonzeroMagnitude // ~1.4e-45
        }

        let rms = try normalizer.measureRMS(buffer: buffer)
        #expect(!rms.isNaN)
        #expect(rms == -180.0, "Subnormal float RMS should clamp to -180 dBFS floor")

        let lufs = try normalizer.measureLUFS(buffer: buffer)
        #expect(!lufs.isNaN)
        #expect(abs(lufs - (-120.691)) < 0.01)

        let peak = try normalizer.measurePeak(buffer: buffer)
        #expect(peak > 0.0)
        #expect(peak < 1e-30)
    }

    // MARK: - 8. Asymmetric / Unequal Length Crossfading

    @Test("Crossfade with asymmetric buffers where window exceeds buffer B length")
    func test_crossfade_window_exceeds_buffer_length() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let lenA: AVAudioFrameCount = 2000
        let lenB: AVAudioFrameCount = 300 // shorter than 15ms (720 samples)

        let bufA = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: lenA)!
        let bufB = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: lenB)!
        bufA.frameLength = lenA
        bufB.frameLength = lenB

        for i in 0..<Int(lenA) { bufA.floatChannelData![0][i] = 1.0 }
        for i in 0..<Int(lenB) { bufB.floatChannelData![0][i] = 2.0 }

        // Requested 0.020s = 960 samples, but bufB is only 300 samples
        let combined = try crossfader.crossfade(
            bufferA: bufA,
            bufferB: bufB,
            windowDuration: 0.020,
            curve: .equalPower
        )

        // Effective fadeLength must clamp to min(lenA, lenB) = 300
        // Expected total length = 2000 + 300 - 300 = 2000
        #expect(combined.frameLength == 2000)
    }

    // MARK: - 9. NaN and Infinity Adversarial Stress Tests

    @Test("NaN in audio buffer propagates without crashing BoundaryCrossfader or LoudnessNormalizer")
    func test_nan_handling() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let frameCount: AVAudioFrameCount = 1000
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let data = buffer.floatChannelData![0]

        // Normal sine wave with a NaN injected at index 500
        for i in 0..<Int(frameCount) {
            data[i] = 0.5 * sin(2.0 * Float.pi * 1000.0 * Float(i) / 48000.0)
        }
        data[500] = Float.nan

        // 1. BoundaryCrossfader must not crash or hang
        try crossfader.applyBoundaryFades(to: buffer, windowDuration: 0.015, curve: .equalPower)
        #expect(data[0] < 0.01)

        // 2. LoudnessNormalizer measurements
        let peak = try normalizer.measurePeak(buffer: buffer)
        // vDSP_maxmgv on data containing NaN
        // Verify it doesn't crash or trigger fatal error
        _ = peak

        let rms = try normalizer.measureRMS(buffer: buffer)
        _ = rms

        let lufs = try normalizer.measureLUFS(buffer: buffer)
        _ = lufs

        // 3. Crossfade with NaN buffer must not memory fault
        let cleanBuffer = makeSineBuffer(durationSeconds: 0.1)
        let combined = try crossfader.crossfade(bufferA: buffer, bufferB: cleanBuffer, windowDuration: 0.015)
        #expect(combined.frameLength > 0)
    }

    @Test("Infinity in audio buffer propagates safely without fatal error")
    func test_infinity_handling() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let frameCount: AVAudioFrameCount = 1000
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let data = buffer.floatChannelData![0]

        for i in 0..<Int(frameCount) { data[i] = 0.2 }
        data[250] = Float.infinity
        data[750] = -Float.infinity

        // Crossfader should execute without crash
        try crossfader.applyBoundaryFades(to: buffer, windowDuration: 0.015, curve: .equalPower)
        #expect(data[0] == 0.0)

        // Peak measurement detects infinity
        let peak = try normalizer.measurePeak(buffer: buffer)
        #expect(peak.isInfinite)
    }
}
