import Testing
import Foundation
import AVFoundation
@testable import MacDubCore

@Suite("Boundary Crossfader Tests")
final class BoundaryCrossfaderTests {
    private let crossfader = BoundaryCrossfader()

    @Test("Boundary crossfader equal-power fade-in and fade-out")
    func test_boundary_fades_equal_power() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let frameCount: AVAudioFrameCount = 48000 // 1.0s
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            Issue.record("Failed to create buffer")
            return
        }
        buffer.frameLength = frameCount
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) { data[i] = 1.0 }

        try crossfader.applyBoundaryFades(to: buffer, windowDuration: 0.015, curve: .equalPower)

        // Head must start near zero
        #expect(data[0] < 0.001)
        // Tail must end near zero
        #expect(data[Int(frameCount) - 1] < 0.001)
        // Midpoint should remain untouched
        #expect(abs(data[Int(frameCount) / 2] - 1.0) < 0.001)
    }

    @Test("Boundary crossfader linear fade-in and fade-out")
    func test_boundary_fades_linear() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let frameCount: AVAudioFrameCount = 48000
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            Issue.record("Failed to create buffer")
            return
        }
        buffer.frameLength = frameCount
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) { data[i] = 1.0 }

        try crossfader.applyBoundaryFades(to: buffer, windowDuration: 0.020, curve: .linear)

        #expect(data[0] < 0.001)
        #expect(data[Int(frameCount) - 1] < 0.001)
        #expect(abs(data[Int(frameCount) / 2] - 1.0) < 0.001)
    }

    @Test("Crossfade two buffers preserves equal-power sum across overlap region")
    func test_crossfade_equal_power_sum() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let frameCountA: AVAudioFrameCount = 24000 // 0.5s
        let frameCountB: AVAudioFrameCount = 24000 // 0.5s

        guard let bufA = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCountA),
              let bufB = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCountB) else {
            Issue.record("Failed to allocate buffers")
            return
        }
        bufA.frameLength = frameCountA
        bufB.frameLength = frameCountB

        // Buffer A has constant amplitude 1.0, Buffer B has constant amplitude 1.0
        for i in 0..<Int(frameCountA) { bufA.floatChannelData![0][i] = 1.0 }
        for i in 0..<Int(frameCountB) { bufB.floatChannelData![0][i] = 1.0 }

        let windowDuration = 0.015 // 15ms = 720 samples at 48kHz
        let combined = try crossfader.crossfade(
            bufferA: bufA,
            bufferB: bufB,
            windowDuration: windowDuration,
            curve: .equalPower
        )

        let fadeLength = Int((windowDuration * 48000).rounded())
        let expectedTotal = Int(frameCountA + frameCountB) - fadeLength
        #expect(Int(combined.frameLength) == expectedTotal)

        let outData = combined.floatChannelData![0]
        let overlapStart = Int(frameCountA) - fadeLength

        // Check equal-power conservation: (wA)^2 + (wB)^2 = 1.0
        // For uncorrelated signals, equal power sum is 1.0.
        // For coherent 1.0 + 1.0 signals, output is wA + wB = cos(theta) + sin(theta)
        // Which is >= 1.0 and <= sqrt(2) ~ 1.414 (no dip below 1.0)
        for i in 0..<fadeLength {
            let val = outData[overlapStart + i]
            #expect(val >= 0.999)
            #expect(val <= 1.415)
        }
    }

    @Test("Boundary crossfader handles short buffers safely")
    func test_short_buffer_safety() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let shortCount: AVAudioFrameCount = 100 // only 100 frames (~2ms), shorter than 15ms window
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: shortCount) else {
            Issue.record("Failed to create buffer")
            return
        }
        buffer.frameLength = shortCount
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(shortCount) { data[i] = 1.0 }

        // Must not crash or out-of-bounds error
        try crossfader.applyBoundaryFades(to: buffer, windowDuration: 0.015, curve: .equalPower)
        #expect(data[0] < 0.01)
        #expect(data[Int(shortCount) - 1] < 0.01)
    }

    @Test("Crossfade rejects mismatched sample rates or channels")
    func test_crossfade_format_mismatch() {
        let formatMono = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let formatStereo = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!

        let bufMono = AVAudioPCMBuffer(pcmFormat: formatMono, frameCapacity: 1000)!
        let bufStereo = AVAudioPCMBuffer(pcmFormat: formatStereo, frameCapacity: 1000)!
        bufMono.frameLength = 1000
        bufStereo.frameLength = 1000

        #expect(throws: BoundaryCrossfaderError.self) {
            try crossfader.crossfade(bufferA: bufMono, bufferB: bufStereo)
        }
    }
}
