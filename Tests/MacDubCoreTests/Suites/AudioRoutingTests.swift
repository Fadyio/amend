import Testing
import Foundation
import AVFoundation
import CoreMedia
@testable import MacDubCore

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
}
