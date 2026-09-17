import Foundation
import AVFoundation
import CoreMedia
import MacDubCore

public enum DurationFittingScenario: Sendable {
    case shorter           // 1.5s (-25%) -> Room tone padding needed
    case minorOverflow     // 2.08s (+4%) -> Automatic pitch-preserving compression
    case boundaryOverflow  // 2.16s (+8%) -> Upper boundary of automatic compression
    case majorOverflow     // 2.30s (+15%) -> Manual overflow gated state

    public var durationSeconds: Double {
        switch self {
        case .shorter: return 1.50
        case .minorOverflow: return 2.08
        case .boundaryOverflow: return 2.16
        case .majorOverflow: return 2.30
        }
    }

    public var overflowPercentage: Double {
        switch self {
        case .shorter: return -25.0
        case .minorOverflow: return 4.0
        case .boundaryOverflow: return 8.0
        case .majorOverflow: return 15.0
        }
    }
}

public enum Fixture3DurationFitting {
    public static let targetSlotDuration = CMTime(value: 20, timescale: 10) // 2.0s
    public static let targetSlotRange = CMTimeRange(
        start: CMTime(value: 10, timescale: 10), // 1.0s
        duration: targetSlotDuration             // 2.0s -> ends at 3.0s
    )

    public static let baseMediaDuration = CMTime(value: 50, timescale: 10) // 5.0s
    public static let roomToneRange = CMTimeRange(
        start: CMTime(value: 0, timescale: 10), // 0.0s
        duration: CMTime(value: 5, timescale: 10) // 0.5s (500ms room tone)
    )

    public static let sampleRate: Double = 44100.0

    public static let targetCue = Cue(
        id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
        timeRange: targetSlotRange,
        text: "Target slot for duration fitting verification",
        originalText: "Target slot for duration fitting verification"
    )

    public static func generateBaseMedia(at fileURL: URL) async throws -> SyntheticAsset {
        let segments: [AudioSegmentSpec] = [
            .silence(duration: CMTime(value: 5, timescale: 10)),                  // 0.0 - 0.5s (room tone silence)
            .silence(duration: CMTime(value: 5, timescale: 10)),                  // 0.5 - 1.0s (pre-cue gap)
            .sineTone(frequency: 550.0, amplitude: 0.5, duration: targetSlotDuration), // 1.0 - 3.0s (original slot speech)
            .silence(duration: CMTime(value: 20, timescale: 10))                 // 3.0 - 5.0s (tail silence)
        ]

        let trackSpec = SyntheticAudioTrackSpec(
            trackName: "DurationFittingBaseNarration",
            segments: segments,
            sampleRate: sampleRate,
            channels: 1
        )

        return try await SyntheticFixtureGenerator.createMovie(
            at: fileURL,
            duration: baseMediaDuration,
            fps: 30,
            videoSize: CGSize(width: 640, height: 360),
            audioTracks: [trackSpec],
            expectedCues: [targetCue],
            roomToneRange: roomToneRange
        )
    }

    public static func createReplacementBuffer(for scenario: DurationFittingScenario) throws -> AVAudioPCMBuffer {
        let duration = CMTime(value: Int64(scenario.durationSeconds * 1000), timescale: 1000)
        return try SyntheticFixtureGenerator.createPCMBuffer(
            duration: duration,
            frequency: 440.0,
            amplitude: 0.5,
            sampleRate: sampleRate
        )
    }

    public static func createReplacementWAV(
        for scenario: DurationFittingScenario,
        at destinationURL: URL
    ) throws -> URL {
        let buffer = try createReplacementBuffer(for: scenario)
        try SyntheticFixtureGenerator.writeWAVFile(buffer: buffer, to: destinationURL)
        return destinationURL
    }
}
