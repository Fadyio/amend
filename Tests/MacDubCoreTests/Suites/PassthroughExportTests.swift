import Testing
import AVFoundation
import CoreMedia
import Foundation
@testable import MacDubCore

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
}
