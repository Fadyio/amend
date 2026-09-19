import Testing
import AVFoundation
import CoreMedia
import Foundation
@testable import AmendCore

@Suite("Waveform Extractor Tests")
struct WaveformExtractorTests {

    private func createAudioMovie() async throws -> SyntheticAsset {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("test_audio.mov")

        let trackSpec = SyntheticAudioTrackSpec(
            trackName: "Narration",
            segments: [
                .silence(duration: CMTime(seconds: 1.0, preferredTimescale: 600)),
                .sineTone(frequency: 440.0, amplitude: 0.8, duration: CMTime(seconds: 2.0, preferredTimescale: 600)),
                .silence(duration: CMTime(seconds: 1.0, preferredTimescale: 600))
            ],
            sampleRate: 44100.0,
            channels: 1
        )

        return try await SyntheticFixtureGenerator.createMovie(
            at: fileURL,
            duration: CMTime(seconds: 4.0, preferredTimescale: 600),
            fps: 30,
            videoSize: CGSize(width: 320, height: 180),
            audioTracks: [trackSpec]
        )
    }

    @Test("Multi-scale pyramid extracts level0, level1, and level2 accurately")
    func test_multiscale_pyramid_extraction() async throws {
        let asset = try await createAudioMovie()
        defer { try? FileManager.default.removeItem(at: asset.fileURL.deletingLastPathComponent()) }

        let extractor = WaveformExtractor()
        let avAsset = AVURLAsset(url: asset.fileURL)
        let trackID = asset.audioTrackIDs[0]

        final class ProgressCollector: @unchecked Sendable {
            var values: [Double] = []
            private let lock = NSLock()
            func append(_ v: Double) {
                lock.lock()
                values.append(v)
                lock.unlock()
            }
        }
        let collector = ProgressCollector()
        let waveform = try await extractor.extractWaveform(
            from: avAsset,
            trackID: trackID,
            cacheDirectory: nil,
            progress: { p in collector.append(p) }
        )

        #expect(waveform.trackID == trackID)
        #expect(waveform.sampleRate == 44100.0)
        #expect(abs(CMTimeGetSeconds(waveform.duration) - 4.0) < 0.1)

        // Level 0: ~100 buckets/sec for 4.0s -> ~400 buckets
        #expect(abs(waveform.level0.count - 400) <= 5)

        // Level 1: ~10 buckets/sec for 4.0s -> ~40 buckets
        #expect(abs(waveform.level1.count - 40) <= 2)

        // Level 2: ~1 bucket/sec for 4.0s -> ~4 buckets
        #expect(abs(waveform.level2.count - 4) <= 1)

        #expect(!collector.values.isEmpty)
        #expect(collector.values.last == 1.0)
    }

    @Test("Energy levels accurately distinguish silence and audio tone")
    func test_energy_levels_silence_vs_tone() async throws {
        let asset = try await createAudioMovie()
        defer { try? FileManager.default.removeItem(at: asset.fileURL.deletingLastPathComponent()) }

        let extractor = WaveformExtractor()
        let avAsset = AVURLAsset(url: asset.fileURL)
        let trackID = asset.audioTrackIDs[0]

        let waveform = try await extractor.extractWaveform(from: avAsset, trackID: trackID, cacheDirectory: nil, progress: nil)

        // Seconds 0.0 - 1.0 is silence (buckets 0..<100 in level0)
        let silenceSlice = waveform.level0[10..<90]
        for bucket in silenceSlice {
            #expect(bucket.rmsSample < 0.01, "Silence RMS must be near zero")
            #expect(bucket.maxSample < 0.01)
            #expect(bucket.minSample > -0.01)
        }

        // Seconds 1.5 - 2.5 is sine tone at 0.8 amplitude (buckets 150..<250 in level0)
        let toneSlice = waveform.level0[150..<250]
        for bucket in toneSlice {
            #expect(bucket.rmsSample > 0.3, "Sine tone RMS must be non-zero")
            #expect(bucket.maxSample > 0.5, "Peak positive amplitude should reflect tone")
            #expect(bucket.minSample < -0.5, "Peak negative amplitude should reflect tone")
        }
    }

    @Test("RenderPeaks produces exact pixelWidth count across different zoom levels")
    func test_render_peaks_resolution() async throws {
        let asset = try await createAudioMovie()
        defer { try? FileManager.default.removeItem(at: asset.fileURL.deletingLastPathComponent()) }

        let extractor = WaveformExtractor()
        let avAsset = AVURLAsset(url: asset.fileURL)
        let trackID = asset.audioTrackIDs[0]

        let waveform = try await extractor.extractWaveform(from: avAsset, trackID: trackID, cacheDirectory: nil, progress: nil)

        let entireRange = CMTimeRange(start: .zero, duration: waveform.duration)

        // Pixel width 200
        let peaks200 = waveform.renderPeaks(for: entireRange, pixelWidth: 200)
        #expect(peaks200.count == 200)

        // Pixel width 500
        let peaks500 = waveform.renderPeaks(for: entireRange, pixelWidth: 500)
        #expect(peaks500.count == 500)

        // Sub-range: 1.0s to 3.0s (duration 2.0s)
        let subRange = CMTimeRange(start: CMTime(seconds: 1.0, preferredTimescale: 600), duration: CMTime(seconds: 2.0, preferredTimescale: 600))
        let peaksSub = waveform.renderPeaks(for: subRange, pixelWidth: 350)
        #expect(peaksSub.count == 350)

        // Edge cases
        #expect(waveform.renderPeaks(for: entireRange, pixelWidth: 0).isEmpty)
        #expect(waveform.renderPeaks(for: .zero, pixelWidth: 100).isEmpty)
    }

    @Test("Binary serialization roundtrip preserves multi-scale buckets exactly")
    func test_binary_serialization_roundtrip() async throws {
        let asset = try await createAudioMovie()
        let tempDir = asset.fileURL.deletingLastPathComponent()
        let binaryURL = tempDir.appendingPathComponent("custom.waveform")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let extractor = WaveformExtractor()
        let avAsset = AVURLAsset(url: asset.fileURL)
        let trackID = asset.audioTrackIDs[0]

        let original = try await extractor.extractWaveform(from: avAsset, trackID: trackID, cacheDirectory: nil, progress: nil)

        try await extractor.saveToBinaryFile(original, at: binaryURL)
        #expect(FileManager.default.fileExists(atPath: binaryURL.path))

        let loaded = try await extractor.loadFromBinaryFile(at: binaryURL, trackID: trackID)

        #expect(loaded.trackID == original.trackID)
        #expect(loaded.sampleRate == original.sampleRate)
        #expect(CMTimeCompare(loaded.duration, original.duration) == 0)
        #expect(loaded.level0.count == original.level0.count)
        #expect(loaded.level1.count == original.level1.count)
        #expect(loaded.level2.count == original.level2.count)

        for i in 0..<min(50, original.level0.count) {
            #expect(abs(loaded.level0[i].rmsSample - original.level0[i].rmsSample) < 1e-6)
            #expect(abs(loaded.level0[i].minSample - original.level0[i].minSample) < 1e-6)
            #expect(abs(loaded.level0[i].maxSample - original.level0[i].maxSample) < 1e-6)
        }
    }

    @Test("Disk caching loads pre-extracted waveform without re-reading asset")
    func test_disk_cache_reloading() async throws {
        let asset = try await createAudioMovie()
        let cacheDir = asset.fileURL.deletingLastPathComponent().appendingPathComponent("wave_cache")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: asset.fileURL.deletingLastPathComponent()) }

        let extractor1 = WaveformExtractor()
        let avAsset = AVURLAsset(url: asset.fileURL)
        let trackID = asset.audioTrackIDs[0]

        let w1 = try await extractor1.extractWaveform(from: avAsset, trackID: trackID, cacheDirectory: cacheDir, progress: nil)

        // Verify file written to disk cache
        let cachedFile = cacheDir.appendingPathComponent("track_\(trackID).waveform")
        #expect(FileManager.default.fileExists(atPath: cachedFile.path))

        // Second extractor should load from disk cache
        let extractor2 = WaveformExtractor()
        let w2 = try await extractor2.extractWaveform(from: avAsset, trackID: trackID, cacheDirectory: cacheDir, progress: nil)

        #expect(w2.level0.count == w1.level0.count)
        #expect(w2.level1.count == w1.level1.count)
    }

    @Test("Duplicate in-flight extraction requests coalesce cleanly")
    func test_duplicate_in_flight_coalescing() async throws {
        let asset = try await createAudioMovie()
        defer { try? FileManager.default.removeItem(at: asset.fileURL.deletingLastPathComponent()) }

        let extractor = WaveformExtractor()
        let avAsset = AVURLAsset(url: asset.fileURL)
        let trackID = asset.audioTrackIDs[0]

        // Launch two extractions concurrently for same track
        async let first = extractor.extractWaveform(from: avAsset, trackID: trackID, cacheDirectory: nil, progress: nil)
        async let second = extractor.extractWaveform(from: avAsset, trackID: trackID, cacheDirectory: nil, progress: nil)

        let (res1, res2) = try await (first, second)
        #expect(res1.level0.count == res2.level0.count)
        #expect(res1.trackID == res2.trackID)
    }
}
