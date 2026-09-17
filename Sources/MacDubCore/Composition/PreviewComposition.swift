import Foundation
import AVFoundation
import CoreMedia

public struct PreviewCompositionGenerator: Sendable {
    public init() {}

    /// Builds an AVMutableComposition splicing synthesized cue WAVs into the designated narration track.
    public func generateComposition(
        sourceURL: URL,
        designatedNarrationTrackID: CMPersistentTrackID,
        passthroughTrackIDs: [CMPersistentTrackID] = [],
        cues: [Cue],
        bundleRootURL: URL? = nil
    ) async throws -> AVMutableComposition {
        let asset = AVURLAsset(url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let totalDuration = try await asset.load(.duration)
        let composition = AVMutableComposition()

        // 1. Video Track Passthrough
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        if let sourceVideoTrack = videoTracks.first {
            guard let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw AudioTrackInspectorError.unreadableAsset(sourceURL, "Failed to create video track in preview composition")
            }
            let timeRange = CMTimeRange(start: .zero, duration: totalDuration)
            try compVideoTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: .zero)
            let transform = try await sourceVideoTrack.load(.preferredTransform)
            compVideoTrack.preferredTransform = transform
        }

        // 2. Passthrough Audio Tracks
        let allAudioTracks = try await asset.loadTracks(withMediaType: .audio)
        for audioTrack in allAudioTracks {
            if passthroughTrackIDs.contains(audioTrack.trackID) {
                guard let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                let timeRange = CMTimeRange(start: .zero, duration: totalDuration)
                try compAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
            }
        }

        // 3. Designated Narration Track Splicing
        guard let sourceNarrationTrack = allAudioTracks.first(where: { $0.trackID == designatedNarrationTrackID }) else {
            return composition
        }

        guard let compNarrationTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return composition
        }

        // Identify edited cues that possess an audio file
        var editedCuesWithAudio: [(cue: Cue, fileURL: URL)] = []
        for cue in cues {
            guard cue.editState != .original, let relPath = cue.audioWAVRelativePath else { continue }
            let fullURL: URL
            if relPath.hasPrefix("/") {
                fullURL = URL(fileURLWithPath: relPath)
            } else if let root = bundleRootURL {
                fullURL = root.appendingPathComponent(relPath)
            } else {
                fullURL = URL(fileURLWithPath: relPath)
            }

            if FileManager.default.fileExists(atPath: fullURL.path) {
                editedCuesWithAudio.append((cue, fullURL))
            }
        }

        // If no cues are edited, pass through the entire narration track untouched
        if editedCuesWithAudio.isEmpty {
            let fullRange = CMTimeRange(start: .zero, duration: totalDuration)
            try compNarrationTrack.insertTimeRange(fullRange, of: sourceNarrationTrack, at: .zero)
            return composition
        }

        // Sort chronologically
        editedCuesWithAudio.sort { CMTimeCompare($0.cue.start, $1.cue.start) < 0 }

        var cursor = CMTime.zero
        for item in editedCuesWithAudio {
            let cue = item.cue
            let cueURL = item.fileURL

            // Insert unedited original audio up to cue start
            if CMTimeCompare(cue.start, cursor) > 0 {
                let gapDur = CMTimeSubtract(cue.start, cursor)
                let gapRange = CMTimeRange(start: cursor, duration: gapDur)
                try compNarrationTrack.insertTimeRange(gapRange, of: sourceNarrationTrack, at: cursor)
            }

            // Insert replacement audio
            let cueAsset = AVURLAsset(url: cueURL)
            let cueAudioTracks = try await cueAsset.loadTracks(withMediaType: .audio)
            if let cueTrack = cueAudioTracks.first {
                let cueDur = try await cueAsset.load(.duration)
                let insertDur = min(cue.duration, cueDur)
                let cueRange = CMTimeRange(start: .zero, duration: insertDur)
                try compNarrationTrack.insertTimeRange(cueRange, of: cueTrack, at: cue.start)
            }

            cursor = cue.end
        }

        // Insert remaining original narration audio after last edited cue
        if CMTimeCompare(cursor, totalDuration) < 0 {
            let tailDur = CMTimeSubtract(totalDuration, cursor)
            let tailRange = CMTimeRange(start: cursor, duration: tailDur)
            try compNarrationTrack.insertTimeRange(tailRange, of: sourceNarrationTrack, at: cursor)
        }

        return composition
    }
}
