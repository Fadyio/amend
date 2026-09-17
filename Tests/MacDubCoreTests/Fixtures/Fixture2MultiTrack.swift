import Foundation
import CoreMedia
import MacDubCore

public enum Fixture2MultiTrack {
    public static let duration = CMTime(value: 100, timescale: 10) // 10.0s
    public static let fps: Int32 = 30
    public static let sampleRate: Double = 44100.0

    public static let groundTruthCues = Fixture1SingleTrack.groundTruthCues
    public static let roomToneRange = Fixture1SingleTrack.roomToneRange

    public static func generate(at fileURL: URL) async throws -> SyntheticAsset {
        // Track 1: Narration (speech tones + silence)
        let narrationSegments: [AudioSegmentSpec] = [
            .silence(duration: CMTime(value: 10, timescale: 10)),         // 0.0 - 1.0s (room tone)
            .sineTone(frequency: 440.0, amplitude: 0.6, duration: CMTime(value: 25, timescale: 10)), // 1.0 - 3.5s (cue 1)
            .silence(duration: CMTime(value: 10, timescale: 10)),         // 3.5 - 4.5s (gap)
            .sineTone(frequency: 880.0, amplitude: 0.6, duration: CMTime(value: 30, timescale: 10)), // 4.5 - 7.5s (cue 2)
            .silence(duration: CMTime(value: 10, timescale: 10)),         // 7.5 - 8.5s (gap)
            .sineTone(frequency: 440.0, amplitude: 0.6, duration: CMTime(value: 10, timescale: 10)), // 8.5 - 9.5s (cue 3)
            .silence(duration: CMTime(value: 5, timescale: 10))           // 9.5 - 10.0s (tail)
        ]

        let narrationTrack = SyntheticAudioTrackSpec(
            trackName: "NarrationTrack",
            segments: narrationSegments,
            sampleRate: sampleRate,
            channels: 1
        )

        // Track 2: Passthrough / Background Ambient (continuous 220Hz tone without gaps)
        let passthroughSegments: [AudioSegmentSpec] = [
            .sineTone(frequency: 220.0, amplitude: 0.25, duration: duration)
        ]

        let passthroughTrack = SyntheticAudioTrackSpec(
            trackName: "PassthroughBackgroundAudio",
            segments: passthroughSegments,
            sampleRate: sampleRate,
            channels: 1
        )

        return try await SyntheticFixtureGenerator.createMovie(
            at: fileURL,
            duration: duration,
            fps: fps,
            videoSize: CGSize(width: 640, height: 360),
            audioTracks: [narrationTrack, passthroughTrack],
            expectedCues: groundTruthCues,
            roomToneRange: roomToneRange
        )
    }
}
