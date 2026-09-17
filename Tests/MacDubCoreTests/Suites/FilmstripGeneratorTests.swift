import Testing
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
@testable import MacDubCore

@Suite("Filmstrip Generator Tests")
struct FilmstripGeneratorTests {

    private func createTestMovie() async throws -> (URL, CMTime) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("test_movie.mov")
        let duration = CMTime(seconds: 2.0, preferredTimescale: 600)
        let asset = try await SyntheticFixtureGenerator.createMovie(
            at: fileURL,
            duration: duration,
            fps: 30,
            videoSize: CGSize(width: 320, height: 180),
            audioTracks: []
        )
        return (asset.fileURL, asset.duration)
    }

    @Test("Generate filmstrip returns thumbnails spanning duration")
    func test_generate_filmstrip_basic() async throws {
        let (fileURL, duration) = try await createTestMovie()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let generator = FilmstripGenerator()
        let request = FilmstripRequest(
            assetURL: fileURL,
            totalDuration: duration,
            pixelsPerSecond: 100.0,
            thumbnailWidth: 50.0,
            thumbnailHeight: 30.0,
            visibleRect: CGRect(x: 0, y: 0, width: 200, height: 30)
        )

        let thumbnails = try await generator.generateFilmstrip(for: request, cacheDirectory: nil)
        #expect(!thumbnails.isEmpty)
        #expect(thumbnails.allSatisfy { $0.image.width > 0 && $0.image.height > 0 })
        #expect(thumbnails.first?.requestedTime == .zero)

        // Verify sorted by id
        for i in 1..<thumbnails.count {
            #expect(thumbnails[i].id > thumbnails[i-1].id)
        }
    }

    @Test("Memory cache avoids re-generating existing thumbnails")
    func test_memory_cache_hit() async throws {
        let (fileURL, duration) = try await createTestMovie()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let generator = FilmstripGenerator()
        let request = FilmstripRequest(
            assetURL: fileURL,
            totalDuration: duration,
            pixelsPerSecond: 100.0,
            thumbnailWidth: 50.0,
            thumbnailHeight: 30.0,
            visibleRect: CGRect(x: 0, y: 0, width: 100, height: 30)
        )

        let firstBatch = try await generator.generateFilmstrip(for: request, cacheDirectory: nil)
        #expect(!firstBatch.isEmpty)

        // Second call should pull directly from memory cache
        let secondBatch = try await generator.generateFilmstrip(for: request, cacheDirectory: nil)
        #expect(secondBatch.count == firstBatch.count)
        #expect(secondBatch[0].image === firstBatch[0].image, "Should return identical CGImage reference from memory cache")

        // Clearing memory cache should yield new CGImage
        generator.clearMemoryCache()
        let thirdBatch = try await generator.generateFilmstrip(for: request, cacheDirectory: nil)
        #expect(thirdBatch[0].image !== firstBatch[0].image, "After clearing memory cache, a new image is generated")
    }

    @Test("Disk cache persists thumbnails to disk and reloads on memory cache miss")
    func test_disk_cache_persistence() async throws {
        let (fileURL, duration) = try await createTestMovie()
        let cacheDir = fileURL.deletingLastPathComponent().appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let generator1 = FilmstripGenerator()
        let request = FilmstripRequest(
            assetURL: fileURL,
            totalDuration: duration,
            pixelsPerSecond: 100.0,
            thumbnailWidth: 50.0,
            thumbnailHeight: 30.0,
            visibleRect: CGRect(x: 0, y: 0, width: 100, height: 30)
        )

        let batch1 = try await generator1.generateFilmstrip(for: request, cacheDirectory: cacheDir)
        #expect(!batch1.isEmpty)

        // Wait brief moment for async background disk writes
        try await Task.sleep(nanoseconds: 50_000_000)

        // Verify disk files exist
        let diskFiles = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        #expect(!diskFiles.isEmpty, "Thumbnails must be written to disk cache directory")

        // New generator with empty memory cache should load from disk
        let generator2 = FilmstripGenerator()
        let batch2 = try await generator2.generateFilmstrip(for: request, cacheDirectory: cacheDir)
        #expect(batch2.count == batch1.count)
        #expect(batch2[0].image.width == batch1[0].image.width)
    }

    @Test("ThumbnailStream yields thumbnails incrementally")
    func test_thumbnail_stream_incremental() async throws {
        let (fileURL, duration) = try await createTestMovie()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let generator = FilmstripGenerator()
        let request = FilmstripRequest(
            assetURL: fileURL,
            totalDuration: duration,
            pixelsPerSecond: 100.0,
            thumbnailWidth: 50.0,
            thumbnailHeight: 30.0,
            visibleRect: CGRect(x: 0, y: 0, width: 200, height: 30)
        )

        var streamed: [FilmstripThumbnail] = []
        for try await thumb in generator.thumbnailStream(for: request, cacheDirectory: nil) {
            streamed.append(thumb)
        }

        #expect(!streamed.isEmpty)
    }

    @Test("Viewport culling confines generated thumbnails to visible bounds plus overdraw")
    func test_viewport_culling() async throws {
        let (fileURL, duration) = try await createTestMovie()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let generator = FilmstripGenerator()
        // Duration is 2s. At 100 pps, total width is 200px.
        // Viewport is 80..120 (seconds 0.8 .. 1.2), prefetchMultiplier 0.0 (no extra overdraw)
        let request = FilmstripRequest(
            assetURL: fileURL,
            totalDuration: duration,
            pixelsPerSecond: 100.0,
            thumbnailWidth: 50.0, // each thumb = 0.5s
            thumbnailHeight: 30.0,
            visibleRect: CGRect(x: 80, y: 0, width: 40, height: 30),
            prefetchMultiplier: 0.0
        )

        let thumbnails = try await generator.generateFilmstrip(for: request, cacheDirectory: nil)
        #expect(!thumbnails.isEmpty)

        // All generated thumbnails should fall near 0.5s to 1.5s
        for thumb in thumbnails {
            let sec = CMTimeGetSeconds(thumb.requestedTime)
            #expect(sec >= 0.4 && sec <= 1.6, "Thumbnail at \(sec)s should be within or adjacent to visible window")
        }
    }
}
