import Foundation
import CoreMedia
@preconcurrency import AVFoundation

public struct CueGenerationResult: Sendable {
    public let cues: [Cue]
    public let roomToneRange: CMTimeRange?
    public let roomToneBuffer: AVAudioPCMBuffer?

    public init(cues: [Cue], roomToneRange: CMTimeRange?, roomToneBuffer: AVAudioPCMBuffer?) {
        self.cues = cues
        self.roomToneRange = roomToneRange
        self.roomToneBuffer = roomToneBuffer
    }
}

public protocol CueGenerating: Sendable {
    func generateCues(
        from audioBuffer: AVAudioPCMBuffer,
        totalDuration: CMTime
    ) async throws -> CueGenerationResult

    func generateCues(
        from audioURL: URL,
        totalDuration: CMTime,
        narrationTrackID: CMPersistentTrackID?
    ) async throws -> CueGenerationResult
}

extension CueGenerating {
    public func generateCues(
        from audioURL: URL,
        totalDuration: CMTime
    ) async throws -> CueGenerationResult {
        try await generateCues(from: audioURL, totalDuration: totalDuration, narrationTrackID: nil)
    }
}

public final class CueGenerator: CueGenerating, @unchecked Sendable {
    private let silenceDetector: SilenceDetecting
    private let transcriptionService: TranscriptionServing

    public init(
        silenceDetector: SilenceDetecting = SilenceDetector(),
        transcriptionService: TranscriptionServing = TranscriptionService()
    ) {
        self.silenceDetector = silenceDetector
        self.transcriptionService = transcriptionService
    }

    public func generateCues(
        from audioBuffer: AVAudioPCMBuffer,
        totalDuration: CMTime
    ) async throws -> CueGenerationResult {
        guard audioBuffer.frameLength > 0, totalDuration > .zero else {
            return CueGenerationResult(cues: [], roomToneRange: nil, roomToneBuffer: nil)
        }

        // 1. Detect speech regions
        let speechRegions = try await silenceDetector.detectSpeechRegions(in: audioBuffer)

        // 2. Transcribe words
        let wordTimings = try await transcriptionService.transcribe(audioBuffer: audioBuffer)

        // 3. Assemble cues from speech regions and word timings
        var generatedCues: [Cue] = []

        if !speechRegions.isEmpty {
            for region in speechRegions {
                // Find all words that fall within or overlap this speech region
                let wordsInRegion = wordTimings.filter { word in
                    let wStart = word.timeRange.start
                    let wEnd = word.timeRange.end
                    return (CMTimeCompare(wStart, region.timeRange.start) >= 0 && CMTimeCompare(wStart, region.timeRange.end) < 0) ||
                           (CMTimeCompare(wEnd, region.timeRange.start) > 0 && CMTimeCompare(wEnd, region.timeRange.end) <= 0) ||
                           (CMTimeCompare(wStart, region.timeRange.start) <= 0 && CMTimeCompare(wEnd, region.timeRange.end) >= 0)
                }

                let text: String
                if !wordsInRegion.isEmpty {
                    text = wordsInRegion.map { $0.word }.joined(separator: " ")
                } else {
                    text = "..." // Speech activity detected without confident word tokens
                }

                let cue = Cue(
                    id: UUID(),
                    timeRange: region.timeRange,
                    text: text,
                    originalText: text,
                    audioWAVRelativePath: nil,
                    editState: .original,
                    words: wordsInRegion
                )
                generatedCues.append(cue)
            }
        } else if !wordTimings.isEmpty {
            // If VAD did not trigger distinct regions, group words into sentences by pause > 0.4s
            var currentWords: [WordTiming] = []
            var cueStart = wordTimings[0].timeRange.start

            for i in 0..<wordTimings.count {
                let word = wordTimings[i]
                currentWords.append(word)

                let isLastWord = i == wordTimings.count - 1
                let hasLongPauseNext: Bool = {
                    guard !isLastWord else { return false }
                    let nextWord = wordTimings[i + 1]
                    let gap = CMTimeSubtract(nextWord.timeRange.start, word.timeRange.end)
                    return CMTimeGetSeconds(gap) >= 0.4
                }()

                let endsWithPunctuation = word.word.hasSuffix(".") || word.word.hasSuffix("?") || word.word.hasSuffix("!")

                if isLastWord || hasLongPauseNext || endsWithPunctuation {
                    let cueEnd = word.timeRange.end
                    let duration = CMTimeSubtract(cueEnd, cueStart)
                    let text = currentWords.map { $0.word }.joined(separator: " ")
                    let cue = Cue(
                        id: UUID(),
                        timeRange: CMTimeRange(start: cueStart, duration: duration),
                        text: text,
                        originalText: text,
                        words: currentWords
                    )
                    generatedCues.append(cue)
                    currentWords.removeAll()
                    if !isLastWord {
                        cueStart = wordTimings[i + 1].timeRange.start
                    }
                }
            }
        }

        // 4. Ensure strictly non-overlapping, chronological ordering
        generatedCues.sort(by: { CMTimeCompare($0.start, $1.start) < 0 })

        // 5. Detect optimal room tone range and extract buffer (ADR-0005)
        let roomToneRange = silenceDetector.findOptimalRoomToneRange(
            in: audioBuffer,
            targetDuration: CMTime(value: 300, timescale: 1000) // 300ms
        )

        let roomToneBuffer: AVAudioPCMBuffer? = {
            guard let range = roomToneRange else { return nil }
            return self.extractSubBuffer(from: audioBuffer, timeRange: range)
        }()

        return CueGenerationResult(
            cues: generatedCues,
            roomToneRange: roomToneRange,
            roomToneBuffer: roomToneBuffer
        )
    }

    public func generateCues(
        from audioURL: URL,
        totalDuration: CMTime,
        narrationTrackID: CMPersistentTrackID? = nil
    ) async throws -> CueGenerationResult {
        let asset = AVURLAsset(url: audioURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            return CueGenerationResult(cues: [], roomToneRange: nil, roomToneBuffer: nil)
        }

        let targetTrackID: CMPersistentTrackID
        if let explicitID = narrationTrackID {
            guard audioTracks.contains(where: { $0.trackID == explicitID }) else {
                throw AudioTrackInspectorError.designatedTrackNotInAsset(Int(explicitID))
            }
            targetTrackID = explicitID
        } else {
            targetTrackID = audioTracks[0].trackID
        }

        let extractor = AudioTrackExtractor()
        let buffer = try await extractor.extractPCMBuffer(from: asset, trackID: targetTrackID, targetSampleRate: 16000.0)
        return try await generateCues(from: buffer, totalDuration: totalDuration)
    }

    private func extractSubBuffer(from source: AVAudioPCMBuffer, timeRange: CMTimeRange) -> AVAudioPCMBuffer? {
        let sampleRate = source.format.sampleRate
        let startFrame = max(0, Int(round(CMTimeGetSeconds(timeRange.start) * sampleRate)))
        let durationFrames = AVAudioFrameCount(round(CMTimeGetSeconds(timeRange.duration) * sampleRate))
        guard durationFrames > 0, (startFrame + Int(durationFrames)) <= Int(source.frameLength) else {
            return nil
        }

        guard let subBuffer = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: durationFrames) else {
            return nil
        }
        subBuffer.frameLength = durationFrames

        let channelCount = Int(source.format.channelCount)
        for ch in 0..<channelCount {
            guard let srcPtr = source.floatChannelData?[ch],
                  let dstPtr = subBuffer.floatChannelData?[ch] else {
                return nil
            }
            dstPtr.update(from: srcPtr.advanced(by: startFrame), count: Int(durationFrames))
        }

        return subBuffer
    }
}
