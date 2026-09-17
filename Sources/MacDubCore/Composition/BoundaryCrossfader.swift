import Foundation
import AVFoundation
import Accelerate

/// The mathematical transition curve applied across crossfade regions.
public enum CrossfadeCurve: Sendable {
    case linear
    case equalPower
}

/// Errors that may occur during boundary fading or crossfading.
public enum BoundaryCrossfaderError: Error, LocalizedError, Equatable, Sendable {
    case invalidBuffer(String)
    case unsupportedAudioFormat(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBuffer(let msg):
            return "Invalid audio buffer: \(msg)"
        case .unsupportedAudioFormat(let msg):
            return "Unsupported audio format: \(msg)"
        }
    }
}

/// Applies 10-20ms boundary fade-in / fade-out and continuous crossfades to prevent audio clicks and pops.
public struct BoundaryCrossfader: Sendable {
    public init() {}

    /// Applies fade-in at the head and fade-out at the tail of the audio buffer in-place.
    public func applyBoundaryFades(
        to buffer: AVAudioPCMBuffer,
        windowDuration: TimeInterval = 0.015, // 15 ms default
        curve: CrossfadeCurve = .equalPower
    ) throws {
        guard let floatChannelData = buffer.floatChannelData else {
            throw BoundaryCrossfaderError.unsupportedAudioFormat("Only 32-bit float PCM buffers are supported.")
        }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        let sampleRate = buffer.format.sampleRate
        var fadeLength = Int((windowDuration * sampleRate).rounded())
        // Clamp fade length to half the buffer if buffer is short
        if fadeLength * 2 > frameCount {
            fadeLength = max(1, frameCount / 2)
        }

        let channelCount = Int(buffer.format.channelCount)
        let denom = Float(max(1, fadeLength - 1))

        for ch in 0..<channelCount {
            let channelPtr = floatChannelData[ch]

            // 1. Fade-in at head
            for i in 0..<fadeLength {
                let factor: Float
                switch curve {
                case .linear:
                    factor = Float(i) / denom
                case .equalPower:
                    let theta = (Float.pi / 2.0) * (Float(i) / denom)
                    factor = sin(theta)
                }
                channelPtr[i] *= factor
            }

            // 2. Fade-out at tail
            let tailStartIndex = frameCount - fadeLength
            for i in 0..<fadeLength {
                let factor: Float
                switch curve {
                case .linear:
                    factor = 1.0 - (Float(i) / denom)
                case .equalPower:
                    let theta = (Float.pi / 2.0) * (Float(i) / denom)
                    factor = cos(theta)
                }
                channelPtr[tailStartIndex + i] *= factor
            }
        }
    }

    /// Crossfades two buffers into a single combined contiguous buffer with overlapping transition.
    public func crossfade(
        bufferA: AVAudioPCMBuffer,
        bufferB: AVAudioPCMBuffer,
        windowDuration: TimeInterval = 0.015,
        curve: CrossfadeCurve = .equalPower
    ) throws -> AVAudioPCMBuffer {
        guard bufferA.format == bufferB.format else {
            throw BoundaryCrossfaderError.invalidBuffer("Buffer audio formats must match for crossfading.")
        }
        guard let format = bufferA.format as AVAudioFormat?,
              let dataA = bufferA.floatChannelData,
              let dataB = bufferB.floatChannelData else {
            throw BoundaryCrossfaderError.unsupportedAudioFormat("Float channel data missing.")
        }

        let lenA = Int(bufferA.frameLength)
        let lenB = Int(bufferB.frameLength)
        let sampleRate = format.sampleRate
        var fadeLength = Int((windowDuration * sampleRate).rounded())
        fadeLength = min(fadeLength, min(lenA, lenB))

        let totalLength = lenA + lenB - fadeLength
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalLength)) else {
            throw BoundaryCrossfaderError.invalidBuffer("Cannot allocate output buffer.")
        }
        output.frameLength = AVAudioFrameCount(totalLength)
        guard let outData = output.floatChannelData else {
            throw BoundaryCrossfaderError.unsupportedAudioFormat("Cannot access output floatChannelData.")
        }

        let channelCount = Int(format.channelCount)
        let unmixedA = lenA - fadeLength
        let denom = Float(max(1, fadeLength - 1))

        for ch in 0..<channelCount {
            let ptrA = dataA[ch]
            let ptrB = dataB[ch]
            let ptrOut = outData[ch]

            // 1. Copy unmixed prefix of buffer A
            if unmixedA > 0 {
                memcpy(ptrOut, ptrA, unmixedA * MemoryLayout<Float>.size)
            }

            // 2. Crossfade overlap region
            for i in 0..<fadeLength {
                let wA: Float
                let wB: Float
                switch curve {
                case .linear:
                    wA = 1.0 - (Float(i) / denom)
                    wB = Float(i) / denom
                case .equalPower:
                    let theta = (Float.pi / 2.0) * (Float(i) / denom)
                    wA = cos(theta)
                    wB = sin(theta)
                }
                ptrOut[unmixedA + i] = (ptrA[unmixedA + i] * wA) + (ptrB[i] * wB)
            }

            // 3. Copy remainder of buffer B
            let remainderB = lenB - fadeLength
            if remainderB > 0 {
                memcpy(ptrOut + lenA, ptrB + fadeLength, remainderB * MemoryLayout<Float>.size)
            }
        }

        return output
    }
}
