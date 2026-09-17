import Foundation
import CoreMedia
@preconcurrency import AVFoundation
import Accelerate

public enum DurationFittingResult: Sendable {
    case fitted(AVAudioPCMBuffer)
    case overflow(delta: CMTime, ratio: Double, uncompressedBuffer: AVAudioPCMBuffer)

    public var isFitted: Bool {
        if case .fitted = self { return true }
        return false
    }

    public var buffer: AVAudioPCMBuffer? {
        switch self {
        case .fitted(let buf): return buf
        case .overflow(_, _, let buf): return buf
        }
    }
}

public protocol DurationFitting: Sendable {
    func fit(
        synthesizedAudio: AVAudioPCMBuffer,
        targetDuration: CMTime,
        roomToneBuffer: AVAudioPCMBuffer?,
        forceCompress: Bool
    ) throws -> DurationFittingResult
}

public final class DurationFitter: DurationFitting, @unchecked Sendable {
    public static let maxAutoCompressionRatio: Double = 1.08 // 8% threshold (ADR-0006)
    public let crossfader: BoundaryCrossfader

    public init(crossfader: BoundaryCrossfader = BoundaryCrossfader()) {
        self.crossfader = crossfader
    }

    public func fit(
        synthesizedAudio: AVAudioPCMBuffer,
        targetDuration: CMTime,
        roomToneBuffer: AVAudioPCMBuffer? = nil,
        forceCompress: Bool = false
    ) throws -> DurationFittingResult {
        guard synthesizedAudio.frameLength > 0, targetDuration > .zero else {
            throw NSError(domain: "DurationFitter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid audio buffer or zero target duration"])
        }

        let sampleRate = synthesizedAudio.format.sampleRate
        let actualSeconds = Double(synthesizedAudio.frameLength) / sampleRate
        let targetSeconds = CMTimeGetSeconds(targetDuration)
        let ratio = actualSeconds / targetSeconds
        let targetFrameCount = AVAudioFrameCount(round(targetSeconds * sampleRate))

        if ratio <= 1.0 {
            // Case 1: Shorter speech -> Retain natural pace and pad with looped ambient room tone (ADR-0005)
            let paddedBuffer = try padWithRoomTone(
                speechBuffer: synthesizedAudio,
                targetFrameCount: targetFrameCount,
                roomToneBuffer: roomToneBuffer
            )
            return .fitted(paddedBuffer)
        } else if ratio <= Self.maxAutoCompressionRatio || forceCompress {
            // Case 2: Within 8% overflow (or user explicitly requested Force Fit) -> Offline time-compression with AVAudioUnitTimePitch
            let compressedBuffer = try timeCompress(
                buffer: synthesizedAudio,
                rate: Float(ratio),
                targetFrameCount: targetFrameCount
            )
            return .fitted(compressedBuffer)
        } else {
            // Case 3: > 8% overflow -> User-gated manual action required (ADR-0006)
            let delta = CMTime(seconds: actualSeconds - targetSeconds, preferredTimescale: 600_000)
            return .overflow(delta: delta, ratio: ratio, uncompressedBuffer: synthesizedAudio)
        }
    }

    // MARK: - Room Tone Padding

    private func padWithRoomTone(
        speechBuffer: AVAudioPCMBuffer,
        targetFrameCount: AVAudioFrameCount,
        roomToneBuffer: AVAudioPCMBuffer?
    ) throws -> AVAudioPCMBuffer {
        guard targetFrameCount >= speechBuffer.frameLength else {
            return speechBuffer
        }

        guard let output = AVAudioPCMBuffer(pcmFormat: speechBuffer.format, frameCapacity: targetFrameCount) else {
            throw NSError(domain: "DurationFitter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate output buffer"])
        }
        output.frameLength = targetFrameCount

        let channels = Int(speechBuffer.format.channelCount)
        let speechFrames = Int(speechBuffer.frameLength)
        let residualFrames = Int(targetFrameCount) - speechFrames

        // Copy speech samples
        for ch in 0..<channels {
            guard let src = speechBuffer.floatChannelData?[ch],
                  let dst = output.floatChannelData?[ch] else { continue }
            dst.update(from: src, count: speechFrames)
        }

        if residualFrames > 0 {
            if let rt = roomToneBuffer, rt.frameLength > 0 {
                // Ensure room tone format matches speech buffer (resample if sample rates or channel counts differ)
                let compatibleRT = resampleBuffer(rt, to: speechBuffer.format) ?? rt
                let rtFrames = Int(compatibleRT.frameLength)
                for ch in 0..<channels {
                    guard let rtSrc = compatibleRT.floatChannelData?[ch % Int(compatibleRT.format.channelCount)],
                          let dst = output.floatChannelData?[ch] else { continue }
                    var filled = 0
                    while filled < residualFrames {
                        let toCopy = min(rtFrames, residualFrames - filled)
                        dst.advanced(by: speechFrames + filled).update(from: rtSrc, count: toCopy)
                        filled += toCopy
                    }
                }
            } else {
                // Digital silence fallback
                for ch in 0..<channels {
                    guard let dst = output.floatChannelData?[ch] else { continue }
                    for i in 0..<residualFrames {
                        dst[speechFrames + i] = 0.0
                    }
                }
            }

            // Apply 15ms boundary crossfade at speech-roomtone transition
            let crossfadeFrames = min(residualFrames / 2, Int(round(speechBuffer.format.sampleRate * 0.015)))
            if crossfadeFrames > 2 {
                let transitionIdx = speechFrames
                for ch in 0..<channels {
                    guard let dst = output.floatChannelData?[ch] else { continue }
                    for f in 0..<crossfadeFrames {
                        let t = Float(f) / Float(crossfadeFrames)
                        let fadeOut = cos(t * .pi / 2.0)
                        let fadeIn = sin(t * .pi / 2.0)
                        let speechSample = dst[transitionIdx - crossfadeFrames + f]
                        let roomSample = dst[transitionIdx + f]
                        dst[transitionIdx + f] = (speechSample * fadeOut) + (roomSample * fadeIn)
                    }
                }
            }
        }

        return output
    }

    // MARK: - Time Compression via AVAudioUnitTimePitch

    private func timeCompress(
        buffer: AVAudioPCMBuffer,
        rate: Float,
        targetFrameCount: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()

        timePitch.rate = rate
        timePitch.pitch = 0.0 // Strictly preserve original pitch

        engine.attach(playerNode)
        engine.attach(timePitch)

        let format = buffer.format
        engine.connect(playerNode, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        playerNode.play()
        playerNode.scheduleBuffer(buffer, completionHandler: nil)

        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: targetFrameCount) else {
            throw NSError(domain: "DurationFitter", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate compressed buffer"])
        }

        let renderChunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        var totalRendered: AVAudioFrameCount = 0

        while totalRendered < targetFrameCount {
            let framesToRender = min(4096, targetFrameCount - totalRendered)
            let status = try engine.renderOffline(framesToRender, to: renderChunk)
            guard status == .success else { break }

            let channels = Int(format.channelCount)
            for ch in 0..<channels {
                guard let src = renderChunk.floatChannelData?[ch],
                      let dst = output.floatChannelData?[ch] else { continue }
                dst.advanced(by: Int(totalRendered)).update(from: src, count: Int(framesToRender))
            }
            totalRendered += framesToRender
        }

        output.frameLength = totalRendered
        engine.stop()
        engine.disableManualRenderingMode()

        // If slight discrepancy under 5 frames, pad to targetFrameCount
        if totalRendered < targetFrameCount {
            let diff = Int(targetFrameCount - totalRendered)
            let channels = Int(format.channelCount)
            for ch in 0..<channels {
                guard let dst = output.floatChannelData?[ch] else { continue }
                for i in 0..<diff {
                    dst[Int(totalRendered) + i] = 0.0
                }
            }
            output.frameLength = targetFrameCount
        }

        return output
    }

    private func resampleBuffer(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == targetFormat { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else { return nil }
        let sampleRateRatio = targetFormat.sampleRate / buffer.format.sampleRate
        let targetCapacity = AVAudioFrameCount(Double(buffer.frameLength) * sampleRateRatio + 100)
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else { return nil }
        var error: NSError?
        var hasProvidedData = false
        converter.convert(to: converted, error: &error) { inNumPackets, outStatus in
            if hasProvidedData {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedData = true
            outStatus.pointee = .haveData
            return buffer
        }
        if error != nil { return nil }
        return converted
    }
}
