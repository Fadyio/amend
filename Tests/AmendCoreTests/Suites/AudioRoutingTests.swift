import Testing
import Foundation
import AVFoundation
import CoreMedia
@testable import AmendCore

@Suite("Audio Routing Tests")
final class AudioRoutingTests {
    private let inspector = AudioTrackInspector()

    @Test("Single-track audio mapping returns singleTrack advisory mapping")
    func test_single_track_mapping() throws {
        let trackInfo = AudioTrackInfo(
            id: 1,
            format: "lpcm",
            channelCount: 1,
            sampleRate: 48000.0,
            bitDepth: 16,
            duration: CMTime(value: 15, timescale: 1),
            timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 15, timescale: 1))
        )

        let mapping = AudioTrackMapping.singleTrack(trackID: 1)
        #expect(mapping.designatedNarrationTrackID == 1)
        #expect(mapping.passthroughTrackIDs.isEmpty)
        #expect(mapping.isSingleTrackAdvisory == true)
        #expect(mapping.isValid == true)

        try inspector.validate(mapping: mapping, against: [trackInfo])
    }

    @Test("Multi-track mapping assigns narration and passthrough tracks")
    func test_multi_track_mapping() throws {
        let tracks = [
            AudioTrackInfo(
                id: 1,
                format: "lpcm",
                channelCount: 1,
                sampleRate: 48000.0,
                duration: CMTime(value: 15, timescale: 1),
                timeRange: .init(start: .zero, duration: CMTime(value: 15, timescale: 1))
            ),
            AudioTrackInfo(
                id: 2,
                format: "aac",
                channelCount: 2,
                sampleRate: 48000.0,
                duration: CMTime(value: 15, timescale: 1),
                timeRange: .init(start: .zero, duration: CMTime(value: 15, timescale: 1))
            )
        ]

        let mapping = AudioTrackMapping.multiTrack(narrationTrackID: 1, passthroughTrackIDs: [2])
        #expect(mapping.designatedNarrationTrackID == 1)
        #expect(mapping.passthroughTrackIDs == [2])
        #expect(mapping.isSingleTrackAdvisory == false)
        #expect(mapping.isValid == true)

        try inspector.validate(mapping: mapping, against: tracks)
    }

    @Test("Validation rejects narration track also present in passthrough")
    func test_validation_rejects_narration_in_passthrough() {
        let tracks = [
            AudioTrackInfo(
                id: 1,
                format: "lpcm",
                channelCount: 1,
                sampleRate: 48000.0,
                duration: CMTime(value: 15, timescale: 1),
                timeRange: .init(start: .zero, duration: CMTime(value: 15, timescale: 1))
            )
        ]

        let invalidMapping = AudioTrackMapping(
            designatedNarrationTrackID: 1,
            passthroughTrackIDs: [1],
            isSingleTrackAdvisory: false
        )
        #expect(invalidMapping.isValid == false)

        #expect(throws: AudioTrackInspectorError.self) {
            try inspector.validate(mapping: invalidMapping, against: tracks)
        }
    }

    @Test("Validation rejects non-existent track ID")
    func test_validation_rejects_nonexistent_track_id() {
        let tracks = [
            AudioTrackInfo(
                id: 1,
                format: "lpcm",
                channelCount: 1,
                sampleRate: 48000.0,
                duration: CMTime(value: 15, timescale: 1),
                timeRange: .init(start: .zero, duration: CMTime(value: 15, timescale: 1))
            )
        ]

        let mapping = AudioTrackMapping.singleTrack(trackID: 999)
        #expect(throws: AudioTrackInspectorError.self) {
            try inspector.validate(mapping: mapping, against: tracks)
        }
    }

    @Test("Validation rejects non-existent passthrough track ID")
    func test_validation_rejects_nonexistent_passthrough_track_id() {
        let tracks = [
            AudioTrackInfo(
                id: 1,
                format: "lpcm",
                channelCount: 1,
                sampleRate: 48000.0,
                duration: CMTime(value: 15, timescale: 1),
                timeRange: .init(start: .zero, duration: CMTime(value: 15, timescale: 1))
            )
        ]

        let mapping = AudioTrackMapping(
            designatedNarrationTrackID: 1,
            passthroughTrackIDs: [999],
            isSingleTrackAdvisory: false
        )
        #expect(throws: AudioTrackInspectorError.self) {
            try inspector.validate(mapping: mapping, against: tracks)
        }
    }

    @Test("Validation rejects duplicate passthrough track IDs")
    func test_validation_rejects_duplicate_passthrough_ids() {
        let tracks = [
            AudioTrackInfo(
                id: 1,
                format: "lpcm",
                channelCount: 1,
                sampleRate: 48000.0,
                duration: CMTime(value: 15, timescale: 1),
                timeRange: .init(start: .zero, duration: CMTime(value: 15, timescale: 1))
            ),
            AudioTrackInfo(
                id: 2,
                format: "aac",
                channelCount: 2,
                sampleRate: 48000.0,
                duration: CMTime(value: 15, timescale: 1),
                timeRange: .init(start: .zero, duration: CMTime(value: 15, timescale: 1))
            )
        ]

        let mapping = AudioTrackMapping(
            designatedNarrationTrackID: 1,
            passthroughTrackIDs: [2, 2],
            isSingleTrackAdvisory: false
        )
        #expect(throws: AudioTrackInspectorError.self) {
            try inspector.validate(mapping: mapping, against: tracks)
        }
    }

    @Test("Validation rejects single-track advisory on multi-track asset")
    func test_validation_rejects_single_track_advisory_on_multitrack_asset() {
        let tracks = [
            AudioTrackInfo(
                id: 1,
                format: "lpcm",
                channelCount: 1,
                sampleRate: 48000.0,
                duration: CMTime(value: 15, timescale: 1),
                timeRange: .init(start: .zero, duration: CMTime(value: 15, timescale: 1))
            ),
            AudioTrackInfo(
                id: 2,
                format: "aac",
                channelCount: 2,
                sampleRate: 48000.0,
                duration: CMTime(value: 15, timescale: 1),
                timeRange: .init(start: .zero, duration: CMTime(value: 15, timescale: 1))
            )
        ]

        let mapping = AudioTrackMapping(
            designatedNarrationTrackID: 1,
            passthroughTrackIDs: [],
            isSingleTrackAdvisory: true
        )
        #expect(throws: AudioTrackInspectorError.self) {
            try inspector.validate(mapping: mapping, against: tracks)
        }
    }

    @Test("Inspector inspects non-existent file and throws fileNotFound")
    func test_inspector_nonexistent_file() async {
        let nonexistentURL = URL(fileURLWithPath: "/tmp/nonexistent_audio_file_\(UUID().uuidString).mov")
        await #expect(throws: AudioTrackInspectorError.self) {
            try await inspector.inspect(assetURL: nonexistentURL)
        }
    }

    @Test("AudioTrackExtractor and CueGenerator extract specifically designated narration track from 2-track movie")
    func test_two_track_audio_extraction_and_cue_generation() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let movieURL = tempDir.appendingPathComponent("two_track_synthetic.mov")
        let duration = CMTime(seconds: 1.0, preferredTimescale: 600)

        // Track 1: 440Hz sine wave
        let track1Spec = SyntheticAudioTrackSpec(
            trackName: "Track1_440Hz",
            segments: [.sineTone(frequency: 440.0, amplitude: 0.7, duration: duration)],
            sampleRate: 44100.0,
            channels: 1
        )

        // Track 2: 880Hz sine wave
        let track2Spec = SyntheticAudioTrackSpec(
            trackName: "Track2_880Hz",
            segments: [.sineTone(frequency: 880.0, amplitude: 0.7, duration: duration)],
            sampleRate: 44100.0,
            channels: 1
        )

        let syntheticAsset = try await SyntheticFixtureGenerator.createMovie(
            at: movieURL,
            duration: duration,
            fps: 30,
            videoSize: CGSize(width: 320, height: 240),
            audioTracks: [track1Spec, track2Spec]
        )

        #expect(syntheticAsset.audioTrackIDs.count == 2)
        let track1ID = syntheticAsset.audioTrackIDs[0]
        let track2ID = syntheticAsset.audioTrackIDs[1]

        let asset = AVURLAsset(url: movieURL)
        let extractor = AudioTrackExtractor()

        // Extract Track 1 (440Hz)
        let buffer1 = try await extractor.extractPCMBuffer(from: asset, trackID: track1ID, targetSampleRate: 16000.0)
        #expect(buffer1.frameLength > 0)

        // Extract Track 2 (880Hz)
        let buffer2 = try await extractor.extractPCMBuffer(from: asset, trackID: track2ID, targetSampleRate: 16000.0)
        #expect(buffer2.frameLength > 0)

        // Calculate zero-crossing counts
        func zeroCrossings(in buffer: AVAudioPCMBuffer) -> Int {
            guard let data = buffer.floatChannelData?[0], buffer.frameLength > 1 else { return 0 }
            var count = 0
            for i in 1..<Int(buffer.frameLength) {
                if (data[i - 1] < 0 && data[i] >= 0) || (data[i - 1] > 0 && data[i] <= 0) {
                    count += 1
                }
            }
            return count
        }

        let zc1 = zeroCrossings(in: buffer1)
        let zc2 = zeroCrossings(in: buffer2)

        // In 1.0s, 440Hz produces ~880 crossings, 880Hz produces ~1760 crossings.
        // zc2 should be approximately double zc1.
        #expect(zc1 >= 800 && zc1 <= 960, "Track 1 (440Hz) expected ~880 crossings, got \(zc1)")
        #expect(zc2 >= 1600 && zc2 <= 1920, "Track 2 (880Hz) expected ~1760 crossings, got \(zc2)")
        #expect(zc2 > zc1 * 3 / 2, "Track 2 (880Hz) must have distinctly higher frequency than Track 1")

        // CueGenerator routing test:
        let detector = EnergySilenceDetector(minSilenceDuration: 0.2, speechPadding: 0.05, energyThresholdDB: -40.0)
        let mockASR = MockTranscriptionService(scriptedTimings: [
            WordTiming(word: "TrackTwo", timeRange: CMTimeRange(start: CMTime(seconds: 0.2, preferredTimescale: 600), duration: CMTime(seconds: 0.5, preferredTimescale: 600)))
        ])
        let cueGenerator = CueGenerator(silenceDetector: detector, transcriptionService: mockASR)

        // Target Track 2
        let result = try await cueGenerator.generateCues(from: movieURL, totalDuration: duration, narrationTrackID: track2ID)
        #expect(!result.cues.isEmpty)
        #expect(result.cues[0].text == "TrackTwo")

        // Strictly verify that the audio buffer received by ASR originates from Track 2 (880Hz) and not Track 1 (440Hz)
        guard let asrBuffer = mockASR.lastTranscribedBuffer else {
            #expect(Bool(false), "ASR should have received audio buffer")
            return
        }
        let asrZC = zeroCrossings(in: asrBuffer)
        #expect(asrZC >= 1600 && asrZC <= 1920, "ASR audio input must originate from selected Track 2 (880Hz, expected ~1760 zero crossings, got \(asrZC))")
        #expect(asrZC > zc1 * 3 / 2, "ASR audio input must be distinctly higher frequency (Track 2) than Track 1")

        // Target non-existent track -> throws error
        await #expect(throws: AudioTrackInspectorError.self) {
            try await cueGenerator.generateCues(from: movieURL, totalDuration: duration, narrationTrackID: 9999)
        }
    }
}
