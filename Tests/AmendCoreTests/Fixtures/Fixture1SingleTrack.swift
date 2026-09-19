import Foundation
import CoreMedia
import AmendCore

public enum Fixture1SingleTrack {
    public static let duration = CMTime(value: 100, timescale: 10) // exactly 10.0s
    public static let fps: Int32 = 30
    public static let sampleRate: Double = 44100.0

    public static let roomToneRange = CMTimeRange(
        start: CMTime(value: 0, timescale: 10),
        duration: CMTime(value: 10, timescale: 10)
    )

    public static let groundTruthCues: [Cue] = [
        Cue(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            timeRange: CMTimeRange(
                start: CMTime(value: 10, timescale: 10), // 1.0s
                duration: CMTime(value: 25, timescale: 10) // 2.5s (ends at 3.5s)
            ),
            text: "Welcome to Amend screen recording",
            originalText: "Welcome to Amend screen recording"
        ),
        Cue(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            timeRange: CMTimeRange(
                start: CMTime(value: 45, timescale: 10), // 4.5s
                duration: CMTime(value: 30, timescale: 10) // 3.0s (ends at 7.5s)
            ),
            text: "This is the second narration segment",
            originalText: "This is the second narration segment"
        ),
        Cue(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            timeRange: CMTimeRange(
                start: CMTime(value: 85, timescale: 10), // 8.5s
                duration: CMTime(value: 10, timescale: 10) // 1.0s (ends at 9.5s)
            ),
            text: "Conclusion and final remarks",
            originalText: "Conclusion and final remarks"
        )
    ]

    public static func generate(at fileURL: URL) async throws -> SyntheticAsset {
        let narrationSegments: [AudioSegmentSpec] = [
            .silence(duration: CMTime(value: 10, timescale: 10)),         // 0.0 - 1.0s (room tone)
            .sineTone(frequency: 440.0, amplitude: 0.6, duration: CMTime(value: 25, timescale: 10)), // 1.0 - 3.5s (cue 1)
            .silence(duration: CMTime(value: 10, timescale: 10)),         // 3.5 - 4.5s (gap)
            .sineTone(frequency: 880.0, amplitude: 0.6, duration: CMTime(value: 30, timescale: 10)), // 4.5 - 7.5s (cue 2)
            .silence(duration: CMTime(value: 10, timescale: 10)),         // 7.5 - 8.5s (gap)
            .sineTone(frequency: 440.0, amplitude: 0.6, duration: CMTime(value: 10, timescale: 10)), // 8.5 - 9.5s (cue 3)
            .silence(duration: CMTime(value: 5, timescale: 10))           // 9.5 - 10.0s (tail)
        ]

        let trackSpec = SyntheticAudioTrackSpec(
            trackName: "Narration",
            segments: narrationSegments,
            sampleRate: sampleRate,
            channels: 1
        )

        return try await SyntheticFixtureGenerator.createMovie(
            at: fileURL,
            duration: duration,
            fps: fps,
            videoSize: CGSize(width: 640, height: 360),
            audioTracks: [trackSpec],
            expectedCues: groundTruthCues,
            roomToneRange: roomToneRange
        )
    }
}
