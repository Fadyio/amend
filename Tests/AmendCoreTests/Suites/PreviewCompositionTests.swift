import Testing
import AVFoundation
import CoreMedia
import Foundation
@testable import AmendCore

@Suite("Preview Composition Tests (Gate G & Phase 12)")
struct PreviewCompositionTests {

    private func createTempDir() throws -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return temp
    }

    private func countZeroCrossings(in buffer: AVAudioPCMBuffer, startSec: Double, durationSec: Double) -> Int {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let sr = buffer.format.sampleRate
        let startFrame = Int(startSec * sr)
        let endFrame = min(Int(buffer.frameLength), Int((startSec + durationSec) * sr))
        guard endFrame > startFrame + 1 else { return 0 }
        var crossings = 0
        for i in (startFrame + 1)..<endFrame {
            let prev = channel[i - 1]
            let curr = channel[i]
            if (prev < 0 && curr >= 0) || (prev > 0 && curr <= 0) {
                crossings += 1
            }
        }
        return crossings
    }

    @Test("Preview composition splices replacement cue audio into designated narration track while preserving passthrough audio")
    func test_preview_composition_generation_and_playback_isolation() async throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceURL = tempDir.appendingPathComponent("multi_source.mov")
        let asset = try await Fixture2MultiTrack.generate(at: sourceURL)
        let narrationTrackID = asset.audioTrackIDs[0]
        let passthroughTrackID = asset.audioTrackIDs[1]

        // Create 1200Hz replacement audio for Cue 1 (1.0s .. 3.5s = 2.5s)
        let replacementWAVURL = tempDir.appendingPathComponent("replacement_preview_cue_1.wav")
        let cueDuration = asset.expectedCues[0].duration
        let replacementBuffer = try SyntheticFixtureGenerator.createPCMBuffer(duration: cueDuration, frequency: 1200.0)
        try SyntheticFixtureGenerator.writeWAVFile(buffer: replacementBuffer, to: replacementWAVURL)

        var editedCues = asset.expectedCues
        editedCues[0] = Cue(
            id: editedCues[0].id,
            timeRange: editedCues[0].timeRange,
            text: "Preview replacement narration (1200Hz)",
            originalText: editedCues[0].originalText,
            audioWAVRelativePath: replacementWAVURL.path,
            editState: .synthesized
        )

        let compGen = PreviewCompositionGenerator()
        let composition = try await compGen.generateComposition(
            sourceURL: sourceURL,
            designatedNarrationTrackID: narrationTrackID,
            passthroughTrackIDs: [passthroughTrackID],
            cues: editedCues
        )

        // 1. Structure Verification
        let duration = try await composition.load(.duration)
        let durSec = CMTimeGetSeconds(duration)
        #expect(abs(durSec - 10.0) < 0.05, "Preview composition duration must match project duration 10.0s")

        let videoTracks = try await composition.loadTracks(withMediaType: .video)
        #expect(videoTracks.count == 1, "Preview composition must contain video track")

        let audioTracks = try await composition.loadTracks(withMediaType: .audio)
        #expect(audioTracks.count == 2, "Preview composition must contain narration + passthrough tracks")

        // 2. Narration Track Audio Analysis
        let extractor = AudioTrackExtractor()
        let narrationPCM = try await extractor.extractPCMBuffer(
            from: composition,
            trackID: audioTracks.last!.trackID, // Narration track is appended
            targetSampleRate: 16000.0
        )
        #expect(narrationPCM.frameLength > 0)

        let cue1Crossings = countZeroCrossings(in: narrationPCM, startSec: 1.5, durationSec: 1.0)
        let cue2Crossings = countZeroCrossings(in: narrationPCM, startSec: 5.0, durationSec: 1.0)

        // Cue 1 (1.0-3.5s) was replaced with 1200Hz audio (~2400 crossings)
        // Untouched Cue 2 (4.5-7.5s) retains original 880Hz audio (~1760 crossings)
        #expect(cue1Crossings >= 2100 && cue1Crossings <= 2700, "Preview Cue 1 must play replacement 1200Hz audio (got \(cue1Crossings) zero crossings)")
        #expect(cue2Crossings >= 1600 && cue2Crossings <= 1920, "Preview untouched Cue 2 must retain original 880Hz audio (got \(cue2Crossings) zero crossings)")
        #expect(cue1Crossings > cue2Crossings, "Replacement preview audio (1200Hz) must have distinctly higher frequency than untouched cue (880Hz)")

        // 3. Passthrough Track Audio Analysis: Track 2 is continuous 220Hz (~440 crossings in 1s)
        let passthroughPCM = try await extractor.extractPCMBuffer(
            from: composition,
            trackID: audioTracks.first!.trackID, // Passthrough track
            targetSampleRate: 16000.0
        )
        let passthroughCrossings = countZeroCrossings(in: passthroughPCM, startSec: 1.5, durationSec: 1.0)
        #expect(passthroughCrossings >= 400 && passthroughCrossings <= 500, "Passthrough audio must retain original 220Hz audio across edited intervals (got \(passthroughCrossings) crossings)")
    }
}
