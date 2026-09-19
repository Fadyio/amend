import Foundation
import AVFoundation
import CoreGraphics
import ImageIO

public struct FilmstripRequest: Sendable, Equatable {
    public let assetURL: URL
    public let totalDuration: CMTime
    public let pixelsPerSecond: Double
    public let thumbnailWidth: Double
    public let thumbnailHeight: Double
    public let visibleRect: CGRect
    public let displayScale: CGFloat
    public let prefetchMultiplier: Double

    public init(
        assetURL: URL,
        totalDuration: CMTime,
        pixelsPerSecond: Double,
        thumbnailWidth: Double = 100.0,
        thumbnailHeight: Double = 60.0,
        visibleRect: CGRect,
        displayScale: CGFloat = 2.0,
        prefetchMultiplier: Double = 1.0
    ) {
        self.assetURL = assetURL
        self.totalDuration = totalDuration
        self.pixelsPerSecond = max(1.0, pixelsPerSecond)
        self.thumbnailWidth = max(10.0, thumbnailWidth)
        self.thumbnailHeight = max(10.0, thumbnailHeight)
        self.visibleRect = visibleRect
        self.displayScale = max(1.0, displayScale)
        self.prefetchMultiplier = max(0.0, prefetchMultiplier)
    }

    public var secondsPerThumbnail: Double {
        thumbnailWidth / pixelsPerSecond
    }

    public var targetPixelSize: CGSize {
        CGSize(
            width: thumbnailWidth * displayScale,
            height: thumbnailHeight * displayScale
        )
    }
}

public struct FilmstripThumbnail: Sendable, Identifiable {
    public let id: Int
    public let requestedTime: CMTime
    public let actualTime: CMTime
    public let image: CGImage
    public let bounds: CGRect

    public init(id: Int, requestedTime: CMTime, actualTime: CMTime, image: CGImage, bounds: CGRect) {
        self.id = id
        self.requestedTime = requestedTime
        self.actualTime = actualTime
        self.image = image
        self.bounds = bounds
    }
}

public enum FilmstripError: Error, LocalizedError {
    case assetLoadingFailed(Error)
    case noVideoTrackFound
    case generationCancelled
    case generationFailed(CMTime, Error)
    case cacheWriteFailed(URL, Error)

    public var errorDescription: String? {
        switch self {
        case .assetLoadingFailed(let err):
            return "Failed to load video asset: \(err.localizedDescription)"
        case .noVideoTrackFound:
            return "No video track found in asset"
        case .generationCancelled:
            return "Thumbnail generation was cancelled"
        case .generationFailed(let time, let err):
            return "Thumbnail generation failed at \(time.seconds)s: \(err.localizedDescription)"
        case .cacheWriteFailed(let url, let err):
            return "Failed to write thumbnail to cache at \(url.path): \(err.localizedDescription)"
        }
    }
}

public protocol FilmstripGenerating: Sendable {
    func generateFilmstrip(
        for request: FilmstripRequest,
        cacheDirectory: URL?
    ) async throws -> [FilmstripThumbnail]

    func thumbnailStream(
        for request: FilmstripRequest,
        cacheDirectory: URL?
    ) -> AsyncThrowingStream<FilmstripThumbnail, Error>

    func clearMemoryCache()
}

public final class FilmstripGenerator: FilmstripGenerating, @unchecked Sendable {
    private let memoryCache = NSCache<NSString, CGImage>()
    private var activeGenerationTask: Task<Void, Never>?
    private var generationID: UInt64 = 0
    private let lock = NSLock()

    public init(maxMemoryCostMB: Int = 25) {
        memoryCache.totalCostLimit = maxMemoryCostMB * 1024 * 1024
        memoryCache.countLimit = 250
    }

    public func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }

    public func generateFilmstrip(
        for request: FilmstripRequest,
        cacheDirectory: URL?
    ) async throws -> [FilmstripThumbnail] {
        var thumbnails: [FilmstripThumbnail] = []
        for try await thumb in thumbnailStream(for: request, cacheDirectory: cacheDirectory) {
            thumbnails.append(thumb)
        }
        return thumbnails.sorted { $0.id < $1.id }
    }

    public func thumbnailStream(
        for request: FilmstripRequest,
        cacheDirectory: URL?
    ) -> AsyncThrowingStream<FilmstripThumbnail, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            activeGenerationTask?.cancel()
            generationID &+= 1
            let currentGen = generationID
            lock.unlock()

            let task = Task {
                do {
                    try await self.executeGeneration(
                        request: request,
                        generationID: currentGen,
                        cacheDirectory: cacheDirectory,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            lock.lock()
            self.activeGenerationTask = task
            lock.unlock()

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func executeGeneration(
        request: FilmstripRequest,
        generationID: UInt64,
        cacheDirectory: URL?,
        continuation: AsyncThrowingStream<FilmstripThumbnail, Error>.Continuation
    ) async throws {
        let deltaT = request.secondsPerThumbnail
        guard deltaT > 0 else { return }
        let totalDurationSec = max(0.0, request.totalDuration.isValid && !request.totalDuration.isIndefinite ? CMTimeGetSeconds(request.totalDuration) : 0.0)
        let totalThumbs = max(1, Int(ceil(totalDurationSec / deltaT)))

        let visStartTime = max(0.0, request.visibleRect.minX / request.pixelsPerSecond)
        let visEndTime = min(totalDurationSec, request.visibleRect.maxX / request.pixelsPerSecond)
        let overdraw = (request.visibleRect.width * request.prefetchMultiplier) / request.pixelsPerSecond
        let fetchStartTime = max(0.0, visStartTime - overdraw)
        let fetchEndTime = min(totalDurationSec, visEndTime + overdraw)

        let firstIndex = max(0, Int(floor(fetchStartTime / deltaT)))
        let lastIndex = min(totalThumbs - 1, Int(ceil(fetchEndTime / deltaT)))
        guard firstIndex <= lastIndex else { return }

        // Center-priority sorting
        let centerIndex = (Int(floor(visStartTime / deltaT)) + Int(ceil(visEndTime / deltaT))) / 2
        let indices = (firstIndex...lastIndex).sorted {
            abs($0 - centerIndex) < abs($1 - centerIndex)
        }

        let asset = AVURLAsset(url: request.assetURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = request.targetPixelSize

        // Bounded adaptive time tolerance
        let toleranceSeconds = min(deltaT * 0.45, 0.25)
        let tolerance = CMTime(seconds: toleranceSeconds, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        for index in indices {
            if Task.isCancelled { break }

            let reqTime = CMTime(seconds: Double(index) * deltaT, preferredTimescale: 600)
            let bounds = CGRect(
                x: Double(index) * request.thumbnailWidth,
                y: 0,
                width: request.thumbnailWidth,
                height: request.thumbnailHeight
            )

            // 1. Check Tier 1 memory cache
            let cacheKey = makeCacheKey(assetURL: request.assetURL, time: reqTime, size: request.targetPixelSize)
            if let cached = memoryCache.object(forKey: cacheKey as NSString) {
                continuation.yield(FilmstripThumbnail(id: index, requestedTime: reqTime, actualTime: reqTime, image: cached, bounds: bounds))
                continue
            }

            // 2. Check Tier 2 disk cache
            if let diskURL = diskCacheURL(cacheDirectory: cacheDirectory, time: reqTime, size: request.targetPixelSize),
               let diskImage = loadDiskImage(at: diskURL) {
                let cost = Int(request.targetPixelSize.width * request.targetPixelSize.height * 4)
                memoryCache.setObject(diskImage, forKey: cacheKey as NSString, cost: cost)
                continuation.yield(FilmstripThumbnail(id: index, requestedTime: reqTime, actualTime: reqTime, image: diskImage, bounds: bounds))
                continue
            }

            // 3. Generate image using AVAssetImageGenerator
            let (cgImage, actualTime) = try await generator.image(at: reqTime)
            let thumb = autoreleasepool { () -> FilmstripThumbnail in
                let cost = Int(request.targetPixelSize.width * request.targetPixelSize.height * 4)
                self.memoryCache.setObject(cgImage, forKey: cacheKey as NSString, cost: cost)

                // Asynchronous disk write
                if let diskURL = self.diskCacheURL(cacheDirectory: cacheDirectory, time: reqTime, size: request.targetPixelSize) {
                    self.saveDiskImage(cgImage, to: diskURL)
                }

                return FilmstripThumbnail(id: index, requestedTime: reqTime, actualTime: actualTime, image: cgImage, bounds: bounds)
            }
            continuation.yield(thumb)
        }
    }

    private func makeCacheKey(assetURL: URL, time: CMTime, size: CGSize) -> String {
        "\(assetURL.path.hashValue)_\(Int64(time.seconds * 1000))_\(Int(size.width))x\(Int(size.height))"
    }

    private func diskCacheURL(cacheDirectory: URL?, time: CMTime, size: CGSize) -> URL? {
        guard let dir = cacheDirectory else { return nil }
        let fileName = "thumb_\(Int64(time.seconds * 1000))_\(Int(size.width))x\(Int(size.height)).jpg"
        return dir.appendingPathComponent(fileName)
    }

    private func loadDiskImage(at url: URL) -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func saveDiskImage(_ image: CGImage, to url: URL) {
        let parentDir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        CGImageDestinationFinalize(destination)
    }
}
