import Testing
import AVFoundation
import CoreMedia
import Foundation
@testable import MacDubCore
import FluidAudio

@Suite("Milestone 4: FluidAudio ASR, VAD & Model Lifecycle Tests")
struct TranscriptionVADTests {

    // MARK: - LocalModelCoordinator Tests (ADR-0009)

    @Test("LocalModelCoordinator strictly serializes model lifecycle and triggers teardown on switch")
    func test_local_model_coordinator_lifecycle_serialization() async throws {
        let coordinator = LocalModelCoordinator()
        #expect(await coordinator.currentState == .idle)

        final class TeardownTracker: @unchecked Sendable {
            var asrTornDown = false
            var ttsTornDown = false
        }
        let tracker = TeardownTracker()

        await coordinator.registerTeardown(for: .asr) {
            tracker.asrTornDown = true
        }
        await coordinator.registerTeardown(for: .tts) {
            tracker.ttsTornDown = true
        }

        // 1. Acquire ASR
        try await coordinator.acquireExclusiveAccess(for: .asr)
        #expect(await coordinator.currentState == .active(.asr))
        #expect(!tracker.asrTornDown)

        // 2. Switch to TTS -> ASR teardown hook MUST be called before TTS becomes active
        try await coordinator.acquireExclusiveAccess(for: .tts)
        #expect(tracker.asrTornDown, "ASR teardown must execute before TTS becomes active")
        #expect(await coordinator.currentState == .active(.tts))

        // 3. Release TTS
        await coordinator.releaseAccess(for: .tts)
        #expect(tracker.ttsTornDown)
        #expect(await coordinator.currentState == .idle)
    }

    @Test("withExclusiveModel runs operation and releases model upon completion or error")
    func test_with_exclusive_model_execution() async throws {
        let coordinator = LocalModelCoordinator()

        let result = try await coordinator.withExclusiveModel(.asr) {
            return "Transcription Output"
        }
        #expect(result == "Transcription Output")
        #expect(await coordinator.currentState == .idle)

        // Throwing operation also safely resets to idle
        do {
            _ = try await coordinator.withExclusiveModel(.asr) {
                throw ModelCoordinatorError.executionFailed("Simulated failure")
            }
            #expect(Bool(false), "Should have thrown")
        } catch {
            #expect(await coordinator.currentState == .idle)
        }
    }

    // MARK: - SilenceDetector & Room Tone Sampling Tests (ADR-0005)

    @Test("SilenceDetector distinguishes speech bursts from silence and extracts optimal room tone")
    func test_silence_detector_and_room_tone() async throws {
        let sampleRate: Double = 44100.0
        // Create 4.0s buffer: [0.0..1.0s silence], [1.0..3.0s tone], [3.0..4.0s silence]
        let totalFrames = AVAudioFrameCount(round(4.0 * sampleRate))
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            #expect(Bool(false), "Failed to allocate audio buffer")
            return
        }
        buffer.frameLength = totalFrames
        let channelData = buffer.floatChannelData![0]

        // Zero out buffer
        for i in 0..<Int(totalFrames) { channelData[i] = 0.0 }

        // Inject 440Hz sine wave into 1.0s .. 3.0s
        let toneStart = Int(1.0 * sampleRate)
        let toneEnd = Int(3.0 * sampleRate)
        for i in toneStart..<toneEnd {
            let t = Double(i - toneStart) / sampleRate
            channelData[i] = Float(sin(2.0 * Double.pi * 440.0 * t)) * 0.7
        }

        let detector = SilenceDetector(minSilenceDuration: 0.3, speechPadding: 0.05, energyThresholdDB: -35.0)

        // 1. Detect speech regions
        let speechRegions = try await detector.detectSpeechRegions(in: buffer)
        #expect(!speechRegions.isEmpty)

        let speech = speechRegions[0]
        let startSec = CMTimeGetSeconds(speech.timeRange.start)
        let endSec = CMTimeGetSeconds(speech.timeRange.end)

        #expect(startSec >= 0.9 && startSec <= 1.1, "Speech start should be near 1.0s, got \(startSec)")
        #expect(endSec >= 2.9 && endSec <= 3.15, "Speech end should be near 3.0s, got \(endSec)")

        // 2. Detect silence regions
        let silences = detector.detectSilenceRegions(in: buffer, speechRegions: speechRegions)
        #expect(silences.count >= 2, "Must identify leading and trailing silence regions")
        #expect(CMTimeGetSeconds(silences[0].start) == 0.0)

        // 3. Find optimal room tone range (300ms)
        let targetDur = CMTime(value: 300, timescale: 1000)
        let roomToneRange = detector.findOptimalRoomToneRange(in: buffer, targetDuration: targetDur)
        #expect(roomToneRange != nil)
        #expect(CMTimeCompare(roomToneRange!.duration, targetDur) == 0)

        // Room tone must be selected from the quiet silence regions, NOT inside the tone
        let rtStart = CMTimeGetSeconds(roomToneRange!.start)
        let isQuietRegion = (rtStart <= 0.7) || (rtStart >= 3.0)
        #expect(isQuietRegion, "Room tone at \(rtStart)s must be sampled from silence")
    }

    // MARK: - Token Aggregation & Transcription Tests

    @Test("TranscriptionService aggregates SentencePiece tokens into full words with timestamps")
    func test_token_aggregation_to_words() {
        let service = TranscriptionService()

        let tokens = [
            TokenTiming(token: " Hello", tokenId: 1, startTime: 0.1, endTime: 0.4, confidence: 0.95),
            TokenTiming(token: " world", tokenId: 2, startTime: 0.5, endTime: 0.8, confidence: 0.92),
            TokenTiming(token: "!", tokenId: 3, startTime: 0.8, endTime: 0.9, confidence: 0.98),
            TokenTiming(token: " This", tokenId: 4, startTime: 1.2, endTime: 1.4, confidence: 0.88),
            TokenTiming(token: " is", tokenId: 5, startTime: 1.4, endTime: 1.6, confidence: 0.91),
            TokenTiming(token: " Mac", tokenId: 6, startTime: 1.7, endTime: 1.9, confidence: 0.96),
            TokenTiming(token: "Dub", tokenId: 7, startTime: 1.9, endTime: 2.1, confidence: 0.94) // Sub-word merge
        ]

        let words = service.aggregateTokensToWords(tokens)
        #expect(words.count == 5)
        #expect(words[0].word == "Hello")
        #expect(words[1].word == "world!")
        #expect(words[2].word == "This")
        #expect(words[3].word == "is")
        #expect(words[4].word == "MacDub") // Merged "Mac" + "Dub"

        #expect(abs(CMTimeGetSeconds(words[0].start) - 0.1) < 0.01)
        #expect(abs(CMTimeGetSeconds(words[4].end) - 2.1) < 0.01)
    }

    // MARK: - CueGenerator Integration Tests

    @Test("CueGenerator maps words into speech slots and extracts room tone buffer")
    func test_cue_generator_integration() async throws {
        let sampleRate: Double = 44100.0
        let totalDuration = CMTime(seconds: 4.0, preferredTimescale: 600_000)
        let totalFrames = AVAudioFrameCount(round(4.0 * sampleRate))

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            #expect(Bool(false))
            return
        }
        buffer.frameLength = totalFrames
        let channelData = buffer.floatChannelData![0]
        for i in 0..<Int(totalFrames) { channelData[i] = 0.0 }

        // Speech burst at 1.0 .. 3.0s
        let toneStart = Int(1.0 * sampleRate)
        let toneEnd = Int(3.0 * sampleRate)
        for i in toneStart..<toneEnd {
            let t = Double(i - toneStart) / sampleRate
            channelData[i] = Float(sin(2.0 * Double.pi * 440.0 * t)) * 0.7
        }

        // Mock transcription returning 3 words inside 1.0s .. 3.0s
        let scriptedWords = [
            WordTiming(word: "Native", timeRange: CMTimeRange(start: CMTime(seconds: 1.1, preferredTimescale: 600), duration: CMTime(seconds: 0.4, preferredTimescale: 600))),
            WordTiming(word: "macOS", timeRange: CMTimeRange(start: CMTime(seconds: 1.6, preferredTimescale: 600), duration: CMTime(seconds: 0.5, preferredTimescale: 600))),
            WordTiming(word: "dubbing", timeRange: CMTimeRange(start: CMTime(seconds: 2.2, preferredTimescale: 600), duration: CMTime(seconds: 0.6, preferredTimescale: 600)))
        ]
        let mockASR = MockTranscriptionService(scriptedTimings: scriptedWords)
        let detector = SilenceDetector(minSilenceDuration: 0.3, speechPadding: 0.05, energyThresholdDB: -35.0)

        let generator = CueGenerator(silenceDetector: detector, transcriptionService: mockASR)
        let result = try await generator.generateCues(from: buffer, totalDuration: totalDuration)

        #expect(result.cues.count == 1)
        let cue = result.cues[0]
        #expect(cue.text == "Native macOS dubbing")
        #expect(cue.originalText == "Native macOS dubbing")
        #expect(cue.editState == .original)

        // Slot duration must match speech region (~2.0s plus padding)
        let cueSeconds = CMTimeGetSeconds(cue.duration)
        #expect(cueSeconds >= 1.8 && cueSeconds <= 2.2)

        // Room tone buffer must be extracted and populated
        #expect(result.roomToneRange != nil)
        #expect(result.roomToneBuffer != nil)
        #expect(result.roomToneBuffer!.frameLength > 0)
    }

    @Test("CueGenerator handles empty or silent audio gracefully")
    func test_cue_generator_silent_audio() async throws {
        let sampleRate: Double = 44100.0
        let totalDuration = CMTime(seconds: 2.0, preferredTimescale: 600_000)
        let totalFrames = AVAudioFrameCount(round(2.0 * sampleRate))

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            #expect(Bool(false))
            return
        }
        buffer.frameLength = totalFrames
        let channelData = buffer.floatChannelData![0]
        for i in 0..<Int(totalFrames) { channelData[i] = 0.0 }

        let mockASR = MockTranscriptionService(scriptedTimings: [])
        let generator = CueGenerator(silenceDetector: SilenceDetector(), transcriptionService: mockASR)

        let result = try await generator.generateCues(from: buffer, totalDuration: totalDuration)
        #expect(result.cues.isEmpty)
        #expect(result.roomToneRange != nil)
        #expect(result.roomToneBuffer != nil)
    }
}
