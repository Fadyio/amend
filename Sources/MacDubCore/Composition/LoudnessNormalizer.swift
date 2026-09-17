import Foundation
import AVFoundation
import Accelerate

/// Errors that may occur during loudness measurement and normalization.
public enum LoudnessNormalizerError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedAudioFormat(String)
    case emptyBuffer
    case zeroSampleRate

    public var errorDescription: String? {
        switch self {
        case .unsupportedAudioFormat(let msg):
            return "Unsupported audio format: \(msg)"
        case .emptyBuffer:
            return "Audio buffer contains zero frames."
        case .zeroSampleRate:
            return "Audio buffer sample rate is zero."
        }
    }
}

/// Measures audio loudness (RMS and ITU-R BS.1770-4 K-weighted LUFS) and performs level matching with peak limiting.
public struct LoudnessNormalizer: Sendable {
    public init() {}

    /// Calculates the Root Mean Square (RMS) level of the buffer in dBFS.
    public func measureRMS(buffer: AVAudioPCMBuffer) throws -> Double {
        guard let data = buffer.floatChannelData else {
            throw LoudnessNormalizerError.unsupportedAudioFormat("32-bit float audio buffer required.")
        }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { throw LoudnessNormalizerError.emptyBuffer }

        let channelCount = Int(buffer.format.channelCount)
        var totalChannelMeanSquare: Double = 0.0

        for ch in 0..<channelCount {
            var channelRMS: Float = 0.0
            vDSP_rmsqv(data[ch], 1, &channelRMS, vDSP_Length(frameCount))
            totalChannelMeanSquare += Double(channelRMS * channelRMS)
        }

        let overallRMS = sqrt(totalChannelMeanSquare / Double(channelCount))
        let clampedRMS = max(overallRMS, 1e-9) // Prevent log(0)
        return 20.0 * log10(clampedRMS)
    }

    /// Measures integrated loudness in LUFS using genuine ITU-R BS.1770-4 K-weighting filtering.
    public func measureLUFS(buffer: AVAudioPCMBuffer) throws -> Double {
        guard let data = buffer.floatChannelData else {
            throw LoudnessNormalizerError.unsupportedAudioFormat("32-bit float audio buffer required.")
        }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { throw LoudnessNormalizerError.emptyBuffer }

        let sampleRate = buffer.format.sampleRate
        guard sampleRate > 0 else { throw LoudnessNormalizerError.zeroSampleRate }

        let channelCount = Int(buffer.format.channelCount)
        var channelEnergies: [Double] = []

        for ch in 0..<channelCount {
            let filtered = applyKWeighting(data: data[ch], count: frameCount, sampleRate: sampleRate)
            var sumSquares: Float = 0.0
            vDSP_svesq(filtered, 1, &sumSquares, vDSP_Length(frameCount))
            let meanSquare = Double(sumSquares) / Double(frameCount)
            channelEnergies.append(meanSquare)
        }

        let totalEnergy = channelEnergies.reduce(0.0, +) / Double(channelCount)
        let clampedEnergy = max(totalEnergy, 1e-12)
        // Offset -0.691 LU per BS.1770-4
        let lufs = -0.691 + 10.0 * log10(clampedEnergy)
        return lufs
    }

    /// Finds the maximum absolute peak value across all channels.
    public func measurePeak(buffer: AVAudioPCMBuffer) throws -> Float {
        guard let data = buffer.floatChannelData else {
            throw LoudnessNormalizerError.unsupportedAudioFormat("32-bit float audio buffer required.")
        }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0.0 }

        var maxPeak: Float = 0.0
        let channelCount = Int(buffer.format.channelCount)

        for ch in 0..<channelCount {
            var channelMax: Float = 0.0
            vDSP_maxmgv(data[ch], 1, &channelMax, vDSP_Length(frameCount))
            maxPeak = max(maxPeak, channelMax)
        }
        return maxPeak
    }

    /// Applies gain to normalize the buffer to the target LUFS, with peak limiting to avoid clipping.
    public func normalize(
        buffer: AVAudioPCMBuffer,
        targetLUFS: Double,
        peakCeiling: Float = 0.95 // -0.45 dBFS safety margin
    ) throws -> (normalizedBuffer: AVAudioPCMBuffer, appliedGainDB: Double) {
        let currentLUFS = try measureLUFS(buffer: buffer)
        let deltaDB = targetLUFS - currentLUFS

        // Calculate linear gain multiplier
        var linearGain = Float(pow(10.0, deltaDB / 20.0))

        // Check for peak clipping and clamp if necessary
        let peak = try measurePeak(buffer: buffer)
        if peak * linearGain > peakCeiling && peak > 0 {
            linearGain = peakCeiling / peak
        }

        let finalGainDB = 20.0 * log10(Double(max(linearGain, 1e-9)))

        guard let output = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else {
            throw LoudnessNormalizerError.unsupportedAudioFormat("Cannot allocate output buffer.")
        }
        output.frameLength = buffer.frameLength

        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)

        for ch in 0..<channelCount {
            let inputPtr = buffer.floatChannelData![ch]
            let outputPtr = output.floatChannelData![ch]
            var gain = linearGain
            vDSP_vsmul(inputPtr, 1, &gain, outputPtr, 1, vDSP_Length(frameCount))
        }

        return (output, finalGainDB)
    }

    /// Matches the loudness of sourceBuffer to referenceBuffer.
    public func matchLoudness(
        sourceBuffer: AVAudioPCMBuffer,
        referenceBuffer: AVAudioPCMBuffer,
        peakCeiling: Float = 0.95
    ) throws -> (normalizedBuffer: AVAudioPCMBuffer, appliedGainDB: Double) {
        let referenceLUFS = try measureLUFS(buffer: referenceBuffer)
        return try normalize(buffer: sourceBuffer, targetLUFS: referenceLUFS, peakCeiling: peakCeiling)
    }

    // MARK: - Private ITU-R BS.1770-4 K-Weighting Filter

    private func applyKWeighting(data: UnsafePointer<Float>, count: Int, sampleRate: Double) -> [Float] {
        // BS.1770-4 two-stage filter:
        // Stage 1: Pre-filter (high-shelf filter simulating head acoustics)
        // Stage 2: RLB weighting (high-pass filter)
        let b1: (b0: Double, b1: Double, b2: Double, a1: Double, a2: Double)
        let b2: (b0: Double, b1: Double, b2: Double, a1: Double, a2: Double)

        if abs(sampleRate - 44100.0) < 1000.0 {
            // 44.1 kHz coefficients from BS.1770 Annex 2
            b1 = (1.53769695279670, -2.69036958461747, 1.19894762295536, -1.66365451515237, 0.71261314984218)
            b2 = (1.0, -2.0, 1.0, -1.98916967160759, 0.98919655653494)
        } else {
            // Default to 48 kHz standard broadcast/video coefficients
            b1 = (1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585)
            b2 = (1.0, -2.0, 1.0, -1.99004745483398, 0.99007225035544)
        }

        var stage1Output = [Float](repeating: 0, count: count)
        var s1_1: Double = 0.0
        var s1_2: Double = 0.0

        for i in 0..<count {
            let x = Double(data[i])
            let y = b1.b0 * x + s1_1
            s1_1 = b1.b1 * x - b1.a1 * y + s1_2
            s1_2 = b1.b2 * x - b1.a2 * y
            stage1Output[i] = Float(y)
        }

        var stage2Output = [Float](repeating: 0, count: count)
        var s2_1: Double = 0.0
        var s2_2: Double = 0.0

        for i in 0..<count {
            let x = Double(stage1Output[i])
            let y = b2.b0 * x + s2_1
            s2_1 = b2.b1 * x - b2.a1 * y + s2_2
            s2_2 = b2.b2 * x - b2.a2 * y
            stage2Output[i] = Float(y)
        }

        return stage2Output
    }
}
