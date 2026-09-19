import Testing
import AVFoundation
import CoreMedia
import Foundation
import CryptoKit
@testable import AmendCore

@Suite("Milestone 6: Compressed-Sample Passthrough Export Tests (ADR 0008)")
struct PassthroughExportTests {

    private func createTempDir() throws -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return temp
    }

    @Test("Passthrough export strictly preserves compressed video sample payload and duration without re-encoding")
    func test_passthrough_export_single_track() async throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceURL = tempDir.appendingPathComponent("source.mov")
        let asset = try await Fixture1SingleTrack.generate(at: sourceURL)

        let exportURL = tempDir.appendingPathComponent("exported.mov")
        let pipeline = PassthroughExportPipeline()

        final class ProgressBox: @unchecked Sendable {
            var values: [Double] = []
            let lock = NSLock()
            func append(_ v: Double) {
                lock.lock()
                values.append(v)
                lock.unlock()
            }
        }
        let box = ProgressBox()

        let config = PassthroughExportConfig(
            sourceURL: sourceURL,
            destinationURL: exportURL,
            designatedNarrationTrackID: asset.audioTrackIDs[0],
            passthroughTrackIDs: [],
            cues: asset.expectedCues
        )

        let result = try await pipeline.export(config: config, progress: { p in box.append(p) })

        #expect(FileManager.default.fileExists(atPath: exportURL.path))
        #expect(!result.wasVideoReencoded, "Video must be remuxed without decoding or re-encoding (ADR-0008)")
        #expect(abs(result.videoSampleCount - 300) <= 5, "Sample count should be ~300 frames")
        #expect(result.videoSampleCount > 0)
        #expect(!box.values.isEmpty)
        #expect(box.values.last == 1.0)

        // Inspect exported asset
        let exportedAsset = AVURLAsset(url: exportURL)
        let exportedDuration = try await exportedAsset.load(.duration)
        let exportedSec = CMTimeGetSeconds(exportedDuration)
        #expect(abs(exportedSec - 10.0) < 0.05, "Exported total duration must equal original duration")

        let vTracks = try await exportedAsset.loadTracks(withMediaType: .video)
        #expect(vTracks.count == 1)
        let naturalSize = try await vTracks[0].load(.naturalSize)
        #expect(naturalSize.width == 640.0)
        #expect(naturalSize.height == 360.0)

        let aTracks = try await exportedAsset.loadTracks(withMediaType: .audio)
        #expect(aTracks.count == 1)
    }

    @Test("Passthrough export preserves multiple independent audio tracks untouched")
    func test_passthrough_export_multi_track() async throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceURL = tempDir.appendingPathComponent("multi_source.mov")
        let asset = try await Fixture2MultiTrack.generate(at: sourceURL)

        let exportURL = tempDir.appendingPathComponent("multi_exported.mov")
        let pipeline = PassthroughExportPipeline()

        let config = PassthroughExportConfig(
            sourceURL: sourceURL,
            destinationURL: exportURL,
            designatedNarrationTrackID: asset.audioTrackIDs[0],
            passthroughTrackIDs: [asset.audioTrackIDs[1]],
            cues: asset.expectedCues
        )

        let result = try await pipeline.export(config: config, progress: nil)

        #expect(FileManager.default.fileExists(atPath: exportURL.path))
        #expect(!result.wasVideoReencoded)

        let exportedAsset = AVURLAsset(url: exportURL)
        let aTracks = try await exportedAsset.loadTracks(withMediaType: .audio)
        #expect(aTracks.count == 2, "Exported media must preserve all 2 audio tracks")
    }

    @Test("Passthrough export throws appropriate error when source file has no video")
    func test_passthrough_export_missing_video_error() async throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Generate audio-only WAV file
        let audioWAV = tempDir.appendingPathComponent("audio_only.wav")
        let pcm = try SyntheticFixtureGenerator.createPCMBuffer(duration: CMTime(seconds: 1.0, preferredTimescale: 600))
        try SyntheticFixtureGenerator.writeWAVFile(buffer: pcm, to: audioWAV)

        let exportURL = tempDir.appendingPathComponent("should_fail.mov")
        let pipeline = PassthroughExportPipeline()
        let config = PassthroughExportConfig(
            sourceURL: audioWAV,
            destinationURL: exportURL,
            designatedNarrationTrackID: 1
        )

        await #expect(throws: ExportError.self) {
            try await pipeline.export(config: config)
        }
    }

    @Test("Passthrough export strictly preserves compressed video sample count and payload hashes while splicing replacement cue WAV into narration")
    func test_passthrough_export_with_replacement_cue_preserves_video_bitstream() async throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceURL = tempDir.appendingPathComponent("source.mov")
        let asset = try await Fixture1SingleTrack.generate(at: sourceURL)

        // Read source compressed video samples and compute per-sample hashes
        let sourceVideoTrackID = asset.videoTrackID!
        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceVideoTracks = try await sourceAsset.loadTracks(withMediaType: .video)
        let sourceTrack = sourceVideoTracks.first(where: { $0.trackID == sourceVideoTrackID })!

        let sourceReader = try AVAssetReader(asset: sourceAsset)
        let sourceVideoOutput = AVAssetReaderTrackOutput(track: sourceTrack, outputSettings: nil)
        sourceVideoOutput.alwaysCopiesSampleData = false
        sourceReader.add(sourceVideoOutput)
        sourceReader.startReading()

        var sourceSampleHashes: [Data] = []
        while let sampleBuffer = sourceVideoOutput.copyNextSampleBuffer() {
            if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                let length = CMBlockBufferGetDataLength(blockBuffer)
                var bufferData = Data(count: length)
                bufferData.withUnsafeMutableBytes { rawBytes in
                    _ = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: rawBytes.baseAddress!)
                }
                sourceSampleHashes.append(Data(SHA256.hash(data: bufferData)))
            }
        }
        #expect(!sourceSampleHashes.isEmpty)

        // Create replacement audio for Cue 1 (1.0s - 3.5s = 2.5s)
        let replacementWAVURL = tempDir.appendingPathComponent("replacement_cue_1.wav")
        let cueDuration = asset.expectedCues[0].duration
        let replacementBuffer = try SyntheticFixtureGenerator.createPCMBuffer(duration: cueDuration, frequency: 1200.0)
        try SyntheticFixtureGenerator.writeWAVFile(buffer: replacementBuffer, to: replacementWAVURL)

        var editedCues = asset.expectedCues
        editedCues[0] = Cue(
            id: editedCues[0].id,
            timeRange: editedCues[0].timeRange,
            text: "Replaced narration with 1200Hz tone",
            originalText: editedCues[0].originalText,
            audioWAVRelativePath: replacementWAVURL.path,
            editState: .edited
        )

        let exportURL = tempDir.appendingPathComponent("exported_spliced.mov")
        let pipeline = PassthroughExportPipeline()
        let config = PassthroughExportConfig(
            sourceURL: sourceURL,
            destinationURL: exportURL,
            designatedNarrationTrackID: asset.audioTrackIDs[0],
            passthroughTrackIDs: [],
            cues: editedCues
        )

        let result = try await pipeline.export(config: config)
        #expect(FileManager.default.fileExists(atPath: exportURL.path))
        #expect(!result.wasVideoReencoded, "Video must not be re-encoded")

        // Read exported compressed video samples and compute per-sample hashes
        let exportedAsset = AVURLAsset(url: exportURL)
        let exportedVideoTracks = try await exportedAsset.loadTracks(withMediaType: .video)
        guard let exportedTrack = exportedVideoTracks.first else {
            #expect(Bool(false), "Exported file missing video track")
            return
        }

        let exportedReader = try AVAssetReader(asset: exportedAsset)
        let exportedVideoOutput = AVAssetReaderTrackOutput(track: exportedTrack, outputSettings: nil)
        exportedVideoOutput.alwaysCopiesSampleData = false
        exportedReader.add(exportedVideoOutput)
        exportedReader.startReading()

        var exportedSampleHashes: [Data] = []
        while let sampleBuffer = exportedVideoOutput.copyNextSampleBuffer() {
            if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                let length = CMBlockBufferGetDataLength(blockBuffer)
                var bufferData = Data(count: length)
                bufferData.withUnsafeMutableBytes { rawBytes in
                    _ = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: rawBytes.baseAddress!)
                }
                exportedSampleHashes.append(Data(SHA256.hash(data: bufferData)))
            }
        }

        // Verify exact byte-for-byte sample count and hashes match source video!
        #expect(exportedSampleHashes.count == sourceSampleHashes.count, "Video sample count must be identical")
        #expect(exportedSampleHashes == sourceSampleHashes, "Video sample payloads must be bitstream identical (zero transcoding)")

        // Verify narration audio track is present in exported asset
        let exportedAudioTracks = try await exportedAsset.loadTracks(withMediaType: .audio)
        #expect(exportedAudioTracks.count == 1, "Exported asset must have reconstructed narration audio track")

        // DEEP AUDIO VERIFICATION (Gate H & Phase 13):
        // Decode exported narration audio and verify that:
        // - Cue 1 interval [1.5s .. 3.0s] contains replacement 1200Hz audio (not original 440Hz)
        // - Untouched Cue 2 interval [4.5s .. 6.0s] contains original 440Hz audio (not 1200Hz)
        let extractor = AudioTrackExtractor()
        let exportedPCM = try await extractor.extractPCMBuffer(
            from: exportedAsset,
            trackID: exportedAudioTracks[0].trackID,
            targetSampleRate: 16000.0
        )
        #expect(exportedPCM.frameLength > 0)

        func countZeroCrossings(in buffer: AVAudioPCMBuffer, startSec: Double, durationSec: Double) -> Int {
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

        // In 1.0s at 16kHz:
        // 1200Hz produces ~2400 zero-crossings.
        // 880Hz produces ~1760 zero-crossings (Fixture 1 Cue 2 tone).
        let cue1Crossings = countZeroCrossings(in: exportedPCM, startSec: 1.5, durationSec: 1.0)
        let cue2Crossings = countZeroCrossings(in: exportedPCM, startSec: 4.5, durationSec: 1.0)

        #expect(cue1Crossings >= 2100 && cue1Crossings <= 2700, "Replacement cue 1 (1.5-2.5s) must contain 1200Hz audio (expected ~2400 crossings, got \(cue1Crossings))")
        #expect(cue2Crossings >= 1600 && cue2Crossings <= 1920, "Untouched cue 2 (4.5-5.5s) must retain original 880Hz audio (expected ~1760 crossings, got \(cue2Crossings))")
        #expect(cue1Crossings > cue2Crossings, "Replacement audio in Cue 1 (1200Hz) must have distinctly higher frequency than untouched audio in Cue 2 (880Hz)")
    }
}
