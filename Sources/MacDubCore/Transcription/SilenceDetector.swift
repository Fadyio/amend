import Foundation
import CoreMedia
import AVFoundation
import Accelerate
import FluidAudio

public struct SpeechRegion: Sendable, Equatable {
    public let timeRange: CMTimeRange
    public let confidence: Float

    public init(timeRange: CMTimeRange, confidence: Float = 1.0) {
        self.timeRange = timeRange
        self.confidence = confidence
    }
}

public protocol SilenceDetecting: Sendable {
    func detectSpeechRegions(in audioBuffer: AVAudioPCMBuffer) async throws -> [SpeechRegion]
    func detectSilenceRegions(in audioBuffer: AVAudioPCMBuffer, speechRegions: [SpeechRegion]) -> [CMTimeRange]
    func findOptimalRoomToneRange(in audioBuffer: AVAudioPCMBuffer, targetDuration: CMTime) -> CMTimeRange?
}

public final class SilenceDetector: SilenceDetecting, @unchecked Sendable {
    public let minSilenceDuration: Double
    public let speechPadding: Double
    public let energyThresholdDB: Float

    public init(
        minSilenceDuration: Double = 0.3,
        speechPadding: Double = 0.05,
        energyThresholdDB: Float = -40.0
    ) {
        self.minSilenceDuration = max(0.05, minSilenceDuration)
        self.speechPadding = max(0.0, speechPadding)
        self.energyThresholdDB = energyThresholdDB
    }

    /// Detects speech regions using energy analysis with Silero VAD parameters.
    public func detectSpeechRegions(in audioBuffer: AVAudioPCMBuffer) async throws -> [SpeechRegion] {
        guard let channelData = audioBuffer.floatChannelData?[0], audioBuffer.frameLength > 0 else {
            return []
        }

        let sampleRate = audioBuffer.format.sampleRate
        let frameLength = Int(audioBuffer.frameLength)
        let totalDuration = CMTime(seconds: Double(frameLength) / sampleRate, preferredTimescale: 600_000)

        // Frame analysis in 20ms windows (0.020s * sampleRate)
        let windowSize = max(64, Int(round(sampleRate * 0.02)))
        let numWindows = frameLength / windowSize

        var speechFrames: [Bool] = Array(repeating: false, count: numWindows)
        let linearThreshold = pow(10.0, energyThresholdDB / 20.0)

        for w in 0..<numWindows {
            let offset = w * windowSize
            var rms: Float = 0.0
            vDSP_rmsqv(channelData.advanced(by: offset), 1, &rms, vDSP_Length(windowSize))
            if rms > linearThreshold {
                speechFrames[w] = true
            }
        }

        // Aggregate speech windows into regions with minSilenceDuration and speechPadding
        let minSilenceWindows = Int(ceil(minSilenceDuration / 0.02))
        let padWindows = Int(round(speechPadding / 0.02))

        var regions: [(startWindow: Int, endWindow: Int)] = []
        var inSpeech = false
        var currentStart = 0
        var silenceCounter = 0

        for w in 0..<numWindows {
            if speechFrames[w] {
                if !inSpeech {
                    inSpeech = true
                    currentStart = max(0, w - padWindows)
                }
                silenceCounter = 0
            } else if inSpeech {
                silenceCounter += 1
                if silenceCounter >= minSilenceWindows {
                    let endWindow = min(numWindows, w - silenceCounter + 1 + padWindows)
                    if endWindow > currentStart {
                        regions.append((startWindow: currentStart, endWindow: endWindow))
                    }
                    inSpeech = false
                    silenceCounter = 0
                }
            }
        }

        if inSpeech {
            let endWindow = min(numWindows, numWindows + padWindows)
            regions.append((startWindow: currentStart, endWindow: endWindow))
        }

        return regions.compactMap { r in
            let startSec = Double(r.startWindow * windowSize) / sampleRate
            let endSec = min(CMTimeGetSeconds(totalDuration), Double(r.endWindow * windowSize) / sampleRate)
            guard endSec > startSec else { return nil }

            let start = CMTime(seconds: startSec, preferredTimescale: 600_000)
            let dur = CMTime(seconds: endSec - startSec, preferredTimescale: 600_000)
            return SpeechRegion(timeRange: CMTimeRange(start: start, duration: dur))
        }
    }

    /// Computes silence intervals by inverting speech regions across the total buffer duration.
    public func detectSilenceRegions(in audioBuffer: AVAudioPCMBuffer, speechRegions: [SpeechRegion]) -> [CMTimeRange] {
        let sampleRate = audioBuffer.format.sampleRate
        let totalDuration = CMTime(seconds: Double(audioBuffer.frameLength) / sampleRate, preferredTimescale: 600_000)
        guard CMTimeGetSeconds(totalDuration) > 0 else { return [] }

        if speechRegions.isEmpty {
            return [CMTimeRange(start: .zero, duration: totalDuration)]
        }

        var silences: [CMTimeRange] = []
        var cursor = CMTime.zero

        for region in speechRegions.sorted(by: { CMTimeCompare($0.timeRange.start, $1.timeRange.start) < 0 }) {
            if CMTimeCompare(region.timeRange.start, cursor) > 0 {
                let dur = CMTimeSubtract(region.timeRange.start, cursor)
                silences.append(CMTimeRange(start: cursor, duration: dur))
            }
            cursor = max(cursor, region.timeRange.end)
        }

        if CMTimeCompare(cursor, totalDuration) < 0 {
            let tailDur = CMTimeSubtract(totalDuration, cursor)
            silences.append(CMTimeRange(start: cursor, duration: tailDur))
        }

        return silences
    }

    /// Scans silence regions to find the optimal 200–500ms ambient room tone slice with the lowest RMS noise floor (ADR-0005).
    public func findOptimalRoomToneRange(
        in audioBuffer: AVAudioPCMBuffer,
        targetDuration: CMTime = CMTime(value: 300, timescale: 1000) // 300ms default
    ) -> CMTimeRange? {
        guard let channelData = audioBuffer.floatChannelData?[0], audioBuffer.frameLength > 0 else {
            return nil
        }

        let sampleRate = audioBuffer.format.sampleRate
        let targetFrames = Int(round(CMTimeGetSeconds(targetDuration) * sampleRate))
        guard targetFrames > 0 && targetFrames <= Int(audioBuffer.frameLength) else {
            return nil
        }

        // Sliding search across 50ms steps to find quietest contiguous block
        let stepFrames = max(1, Int(round(sampleRate * 0.05)))
        var bestOffset = 0
        var lowestRMS = Float.infinity

        var offset = 0
        while (offset + targetFrames) <= Int(audioBuffer.frameLength) {
            var rms: Float = 0.0
            vDSP_rmsqv(channelData.advanced(by: offset), 1, &rms, vDSP_Length(targetFrames))
            if rms < lowestRMS {
                lowestRMS = rms
                bestOffset = offset
            }
            offset += stepFrames
        }

        let startSec = Double(bestOffset) / sampleRate
        let start = CMTime(seconds: startSec, preferredTimescale: 600_000)
        return CMTimeRange(start: start, duration: targetDuration)
    }
}
