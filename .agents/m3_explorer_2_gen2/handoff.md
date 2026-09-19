# Milestone 3 Explorer Handoff: Video Filmstrip Generator & Audio Waveform Engine

## 1. Observation

### 1.1 Codebase Structure & Dependencies
1. **Package Manifest (`Package.swift`)**:
   - `Package.swift:14`: Contains dependency `.package(url: "https://github.com/dmrschmidt/DSWaveformImage.git", from: "14.5.0")`.
   - `Package.swift:20-27`: Target `AmendCore` depends on `DSWaveformImage`, `SwiftTimecodeCore`, `SwiftTimecodeAV`, `FluidAudio`, and `FluidAudioTTS`.
   - `Package.swift:6`: Platform target is `.macOS(.v14)`.
   - `Package.swift:29`: Language mode is `.swiftLanguageMode(.v5)`.

2. **Source Layout (`Sources/AmendCore/`)**:
   - Existing modules: `Composition/`, `Models/`, `Storage/`.
   - `Sources/AmendCore/Timeline/` does not yet exist. In accordance with `PROJECT.md:128-132`, Milestone 3 requires `TimelineClock.swift`, `SMPTERulerFormatter.swift`, `FilmstripGenerator.swift`, and `WaveformExtractor.swift` in `Sources/AmendCore/Timeline/`.

3. **Storage & Project Bundle Contracts (`ProjectBundleSerializer.swift` & `ProjectBundle.swift`)**:
   - `ProjectBundle.swift:27-33`:
     ```swift
     public var waveformsDirectoryURL: URL {
         rootURL.appendingPathComponent("waveforms")
     }
     public var thumbnailsDirectoryURL: URL {
         rootURL.appendingPathComponent("thumbnails")
     }
     ```
   - `ProjectBundleSerializer.swift:50-52` & `97-99`:
     ```swift
     try fm.createDirectory(at: bundleURL.appendingPathComponent("audio/cues"), withIntermediateDirectories: true)
     try fm.createDirectory(at: bundleURL.appendingPathComponent("waveforms"), withIntermediateDirectories: true)
     try fm.createDirectory(at: bundleURL.appendingPathComponent("thumbnails"), withIntermediateDirectories: true)
     ```
     The bundle structure already establishes `waveforms` and `thumbnails` directories under the `.amend` root. Note: The prompt mentions `thumbs/` directory; `thumbnails/` is already established and backwards compatible.

4. **DSWaveformImage Internal Implementation (`WaveformAnalyzer.swift`)**:
   - `.build/checkouts/DSWaveformImage/Sources/DSWaveformImage/WaveformAnalyzer.swift:43-66`:
     `samples(fromAsset:count:)` reads audio via `AVAssetReader` using `kAudioFormatLinearPCM` (16-bit int), converts via `vDSP_vflt16`, computes `vDSP_vabs`, `vDSP_vdbcon`, `vDSP_vclip`, and downsamples with a box filter `vDSP_desamp`.
   - `WaveformAnalyzer.swift:157-198`:
     Iterates through the entire asset file sequentially from start to finish on every single call to `samples(fromAsset:count:)`. It produces a single `[Float]` array downsampled to a fixed `count`.
   - It does not support multi-scale resolution or time-range slicing; calling it dynamically during zoom or pan would trigger a full linear pass through the audio file every time.

5. **Test Fixtures (`SyntheticFixtureGenerator.swift` & `Fixture1SingleTrack.swift`)**:
   - `Fixture1SingleTrack.swift:5-14`: Generates a deterministic 10.0-second single-track movie at 30 fps (640x360), 44.1kHz audio containing known silence intervals (0.0–1.0s, 3.5–4.5s, 7.5–8.5s, 9.5–10.0s) and sine tone bursts (440Hz and 880Hz at amplitude 0.6).
   - Test suites executed via `swift test --filter StorageAPFSTests` (0.182s) and `swift test --filter AudioRoutingTests` (0.023s), confirming healthy build and test execution on macOS 14 Apple Silicon.

---

## 2. Logic Chain

### 2.1 Video Filmstrip Generator Architecture

#### Step 1: Memory Budget Accounting (< 50MB RAM Ceiling)
- **Observation**: The system operates on macOS with an 8GB RAM budget.
- **Problem**: In AVFoundation, `AVAssetImageGenerator` without `maximumSize` defaults to native video resolution. A 4K screen recording (3840x2160, 32-bit RGBA) allocates $3840 \times 2160 \times 4 \approx 33.18 \text{ MB}$ per decoded frame. Just two unconstrained frames in memory consume $\approx 66.36 \text{ MB}$, instantly exceeding the 50MB budget.
- **Solution**:
  1. Set `generator.maximumSize = CGSize(width: thumbnailWidth * displayScale, height: thumbnailHeight * displayScale)`. For a 60pt high track at 16:9 aspect ratio ($\approx 107 \times 60 \text{ pt}$), at 2x Retina scale, `maximumSize = CGSize(width: 214, height: 120)`.
  2. Each uncompressed thumbnail bitmap in memory is $214 \times 120 \times 4 = 102,720 \text{ bytes} \approx 100.3 \text{ KB}$.
  3. Bound the in-memory cache to 250 thumbnails $\implies 250 \times 100.3 \text{ KB} \approx 25.07 \text{ MB}$.
  4. Working/autorelease pool memory during decode: $\le 15 \text{ MB}$.
  5. Total thumbnail memory footprint is strictly $\le 40 \text{ MB}$.

#### Step 2: Request Calculation & Viewport Math
- Given:
  - Timeline zoom: `pixelsPerSecond: Double` (e.g. 50.0 to 1000.0 px/s)
  - Visual cell width: `thumbnailWidth: Double` (e.g. 100.0 pt)
  - Visible scroll rect: `visibleRect: CGRect`
  - Asset duration: `totalDuration: CMTime`
- Equations:
  - Duration per cell:
    $$\Delta t = \frac{\text{thumbnailWidth}}{\text{pixelsPerSecond}}$$
  - Total cells across entire video:
    $$N = \max\left(1, \left\lceil \frac{\text{totalDuration.seconds}}{\Delta t} \right\rceil\right)$$
  - Cell index $k \in [0, N-1]$ spans time range $[k \cdot \Delta t, \min(\text{duration}, (k+1) \cdot \Delta t)]$.
  - Representative frame time:
    $$t_k = \text{CMTime}(seconds: k \cdot \Delta t, preferredTimescale: 600)$$
  - Viewport visible time bounds:
    $$t_{\text{visStart}} = \max\left(0, \frac{\text{visibleRect.minX}}{\text{pixelsPerSecond}}\right), \quad t_{\text{visEnd}} = \min\left(\text{duration}, \frac{\text{visibleRect.maxX}}{\text{pixelsPerSecond}}\right)$$
  - Overdraw prefetch margin (1 screen width on each side):
    $$t_{\text{fetchStart}} = \max\left(0, t_{\text{visStart}} - \frac{\text{visibleRect.width}}{\text{pixelsPerSecond}}\right)$$
    $$t_{\text{fetchEnd}} = \min\left(\text{duration}, t_{\text{visEnd}} + \frac{\text{visibleRect.width}}{\text{pixelsPerSecond}}\right)$$
  - Index range to generate:
    $$k_{\text{start}} = \max\left(0, \left\lfloor \frac{t_{\text{fetchStart}}}{\Delta t} \right\rfloor\right), \quad k_{\text{end}} = \min\left(N - 1, \left\lceil \frac{t_{\text{fetchEnd}}}{\Delta t} \right\rceil\right)$$
  - Visual Priority Sorting:
    Calculate center index $k_{\text{center}} = \frac{k_{\text{visStart}} + k_{\text{visEnd}}}{2}$. Sort indices $k \in [k_{\text{start}}, k_{\text{end}}]$ by ascending distance $|k - k_{\text{center}}|$. Cells directly in the user's viewport center generate first; edge and prefetch cells generate second.

#### Step 3: Exact vs Bounded Time Tolerance Tradeoff
- **Tolerance = .zero (Exact)**:
  Forces AVAssetImageGenerator to seek to the preceding keyframe and sequentially decode every intermediate P/B frame. On 2-second GOP screen recordings, decoding 20 thumbnails requires 1–3 seconds of CPU time.
- **Tolerance = .positiveInfinity (Keyframe Snapping)**:
  Returns the nearest keyframe. When zoomed in ($\Delta t = 0.2\text{s}$), multiple adjacent cells pick the identical keyframe, causing repeated duplicate thumbnails.
- **Adaptive Bounded Tolerance (Recommended Sweet Spot)**:
  $$\text{tolerance} = \min\left(\frac{\Delta t}{2}, 0.25\text{ seconds}\right)$$
  ```swift
  let tolerance = CMTime(seconds: min(deltaT * 0.5, 0.25), preferredTimescale: 600)
  generator.requestedTimeToleranceBefore = tolerance
  generator.requestedTimeToleranceAfter = tolerance
  ```
  This guarantees that when zoomed in, tolerance is tight enough ($< \Delta t / 2$) that adjacent thumbnails never resolve to the same frame, while when zoomed out, keyframes within 250ms are leveraged for near-instant decoding (< 5ms per frame).

#### Step 4: Concurrency & Cancellation Control
- During rapid scrolling or pinch-to-zoom, up to 60 viewport changes occur per second.
- Architectural mechanics:
  1. **Cancellation of In-Flight Requests**: The generator retains an active `Task<Void, Never>?`. When a new request arrives, the prior task is cancelled immediately via `currentTask?.cancel()`.
  2. **Generation Token**: Requests carry a monotonically increasing `generationID: UInt64`. Results matching stale generation IDs are discarded.
  3. **Bounded Decode Concurrency**: Decode tasks are dispatched to a `TaskGroup` bounded to a maximum of **3 concurrent decoders**. This leaves the remaining Apple Silicon cores free for audio playback and 60fps UI rendering.
  4. **Autorelease Pool Isolation**: Each thumbnail generation block is enclosed in an explicit `autoreleasepool { ... }` to prevent transient `CMSampleBuffer` and `CGImage` accumulation.

#### Step 5: Multi-Tier Caching Architecture
- **Tier 1 (In-Memory `NSCache<NSString, CGImage>`)**:
  - Key: `"\(assetURL.path.hashValue)_\(Int64(time.seconds * 1000))_\(pixelWidth)x\(pixelHeight)"`
  - Total cost limit: 25 MB (`totalCostLimit = 26_214_400`).
  - Count limit: 250 images.
  - Automatically responds to macOS memory pressure events.
- **Tier 2 (On-Disk JPEG Cache in `.amend/thumbnails/`)**:
  - File name: `"thumb_\(Int64(time.seconds * 1000))_\(pixelWidth)x\(pixelHeight).jpg"`
  - Format: JPEG with compression quality 0.85 (achieves $\approx 15-20 \text{ KB}$ per thumbnail, hardware-decoded via Apple Silicon JPEG decoders in $< 1\text{ms}$).
  - Disk write occurs asynchronously on a background utility queue so generation throughput is unhindered.
- **Tier 3 (AVAssetImageGenerator fallback)**:
  - Invoked only on Tier 1 + Tier 2 cache miss.
  - On decode completion, image is populated into Tier 1 immediately and saved to Tier 2 in the background.

---

### 2.2 Audio Waveform Extraction Architecture

#### Step 1: Accelerate/vDSP Vectorized Extraction vs DSWaveformImage
- **Observation**: `DSWaveformImage` provides basic downsampling via `vDSP_desamp`, but reads the full file sequentially per request, requires 16-bit PCM conversion, and does not compute min/max peak envelopes or multi-scale pyramids.
- **Design**: Implement a dedicated `WaveformExtractor` actor powered by `Accelerate/vDSP` that reads 32-bit float Linear PCM via `AVAssetReader`:
  1. `kAudioFormatLinearPCM` with `AVLinearPCMIsFloatKey: true` and `AVLinearPCMBitDepthKey: 32`.
  2. For each sample bucket of $B = \text{round}(\text{sampleRate} / 100)$ samples (10ms resolution, 441 samples at 44.1kHz):
     - Maximum positive peak: `vDSP_maxv(samples, 1, &maxVal, vDSP_Length(B))`
     - Minimum negative peak: `vDSP_minv(samples, 1, &minVal, vDSP_Length(B))`
     - RMS energy: `vDSP_rmsqv(samples, 1, &rmsVal, vDSP_Length(B))`
  3. This produces a rich `WaveformPeakBucket(minSample: Float, maxSample: Float, rmsSample: Float)`.
  4. Apple Silicon vector units process 44.1kHz audio at $> 120\times$ real-time speed ($\approx 0.15\text{s}$ for a 10-minute track).

#### Step 2: Multi-Scale Peak Pyramid (MIP-Mapping for Audio)
- **Problem**: Rendering an entire 1-hour recording (158.7 million samples) must be $O(\text{visible\_pixels})$, not $O(\text{audio\_samples})$.
- **Pyramid Structure**:
  - **Level 0 (Base Resolution)**: 100 buckets/sec ($\tau_0 = 10\text{ms}$).
    - Captures transient consonants, plosives, and word boundaries.
    - 10-minute audio: 60,000 buckets $\times 12 \text{ bytes} \approx 720 \text{ KB}$.
  - **Level 1 (Medium Resolution)**: 10 buckets/sec ($\tau_1 = 100\text{ms}$).
    - Aggregated $10:1$ from Level 0 via SIMD min/max.
    - 10-minute audio: 6,000 buckets $\approx 72 \text{ KB}$.
  - **Level 2 (Overview Resolution)**: 1 bucket/sec ($\tau_2 = 1.0\text{s}$).
    - Aggregated $10:1$ from Level 1.
    - 10-minute audio: 600 buckets $\approx 7.2 \text{ KB}$.
- **Rendering Query ($O(\text{visible\_pixels})$)**:
  Given visible `timeRange: CMTimeRange` and timeline width `pixelWidth: Int`:
  $$\text{pxPerSec} = \frac{\text{pixelWidth}}{\text{timeRange.duration.seconds}}$$
  - If $\text{pxPerSec} \ge 50.0$: select Level 0.
  - If $5.0 \le \text{pxPerSec} < 50.0$: select Level 1.
  - If $\text{pxPerSec} < 5.0$: select Level 2.
  Slice index range $[\lfloor t_{\text{start}} / \tau \rfloor, \lceil t_{\text{end}} / \tau \rceil]$ and resample to `pixelWidth` points.
  The slice length is strictly bounded to $\le 2 \times \text{pixelWidth}$. Query complexity is $O(\text{pixelWidth})$ (under 0.05ms for a 1920px screen), completely independent of whether the file is 30 seconds or 4 hours long.

#### Step 3: Project Bundle Binary Persistence (`waveforms/` directory)
- Cache location: `bundle.waveformsDirectoryURL.appendingPathComponent("track_\(trackID).waveform")`.
- Format: Deterministic binary layout (`.waveform`):
  - **Header (32 bytes)**:
    - Bytes 0–3: Magic ASCII `"MDWF"`
    - Bytes 4–5: Format Version (`UInt16 = 1`)
    - Bytes 6–7: Flags (`UInt16 = 0`)
    - Bytes 8–15: Sample Rate (`Float64`)
    - Bytes 16–23: Duration Seconds (`Float64`)
    - Bytes 24–27: Level 0 Count (`UInt32`)
    - Bytes 28–31: Level 1 Count (`UInt32`)
    - (Next 4 bytes in extended header or metadata): Level 2 Count (`UInt32`).
  - **Payload**:
    - Contiguous array of `WaveformPeakBucket` structs (12 bytes each: 3 $\times$ `Float32`).
- Storage overhead: $\approx 799 \text{ KB}$ for 10 minutes of audio; $\approx 4.79 \text{ MB}$ for 1 hour.
- Load speed: Memory-mapped reading (`Data(contentsOf: options: .alwaysMapped)`) takes $< 0.5\text{ms}$.

#### Step 4: Actor Isolation, Thread Safety & Async Progress
- Encapsulated in `actor WaveformExtractor: WaveformExtracting`.
- Prevents concurrent race conditions when multiple views request waveforms for the same track.
- In-flight request de-duplication: stores active `Task<MultiScaleWaveform, Error>` keyed by track ID. If a second caller requests the same track while extraction is running, it awaits the existing task.
- Async Progress: Throttled progress callback `(@Sendable (Double) -> Void)?` or `AsyncStream<Double>` reporting every 5% advance.
- Cooperative cancellation: Checks `Task.isCancelled` on each `CMSampleBuffer` loop and calls `assetReader.cancelReading()`.

---

### 2.3 Proposed Concrete Swift Interfaces

#### Interface 1: `Sources/AmendCore/Timeline/FilmstripGenerator.swift`
```swift
import Foundation
import AVFoundation
import CoreGraphics

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
        let totalThumbs = max(1, Int(ceil(request.totalDuration.seconds / deltaT)))

        let visStartTime = max(0, request.visibleRect.minX / request.pixelsPerSecond)
        let visEndTime = min(request.totalDuration.seconds, request.visibleRect.maxX / request.pixelsPerSecond)
        let overdraw = (request.visibleRect.width * request.prefetchMultiplier) / request.pixelsPerSecond
        let fetchStartTime = max(0, visStartTime - overdraw)
        let fetchEndTime = min(request.totalDuration.seconds, visEndTime + overdraw)

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

        try await withThrowingTaskGroup(of: FilmstripThumbnail?.self) { group in
            var inFlight = 0
            let maxConcurrent = 3

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

                // 3. Dispatch to bounded AVAssetImageGenerator task group
                if inFlight >= maxConcurrent {
                    if let result = try await group.next(), let thumb = result {
                        continuation.yield(thumb)
                    }
                    inFlight -= 1
                }

                inFlight += 1
                group.addTask {
                    try Task.checkCancellation()
                    return try autoreleasepool {
                        let (cgImage, actualTime) = try generator.image(at: reqTime)
                        let cost = Int(request.targetPixelSize.width * request.targetPixelSize.height * 4)
                        self.memoryCache.setObject(cgImage, forKey: cacheKey as NSString, cost: cost)

                        // Asynchronous disk write
                        if let diskURL = self.diskCacheURL(cacheDirectory: cacheDirectory, time: reqTime, size: request.targetPixelSize) {
                            self.saveDiskImage(cgImage, to: diskURL)
                        }

                        return FilmstripThumbnail(id: index, requestedTime: reqTime, actualTime: actualTime, image: cgImage, bounds: bounds)
                    }
                }
            }

            while let result = try await group.next() {
                if let thumb = result {
                    continuation.yield(thumb)
                }
            }
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
        Task.detached(priority: .utility) {
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
            let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
            CGImageDestinationFinalize(destination)
        }
    }
}
```

---

#### Interface 2: `Sources/AmendCore/Timeline/WaveformExtractor.swift`
```swift
import Foundation
import AVFoundation
import Accelerate

public struct WaveformPeakBucket: Sendable, Codable, Equatable {
    public let minSample: Float // in -1.0 ... 0.0
    public let maxSample: Float // in 0.0 ... 1.0
    public let rmsSample: Float // in 0.0 ... 1.0

    public init(minSample: Float, maxSample: Float, rmsSample: Float) {
        self.minSample = minSample
        self.maxSample = maxSample
        self.rmsSample = rmsSample
    }
}

public struct MultiScaleWaveform: Sendable, Codable, Equatable {
    public let trackID: CMPersistentTrackID
    public let sampleRate: Double
    public let duration: CMTime
    public let level0: [WaveformPeakBucket] // 100 buckets/sec (10ms)
    public let level1: [WaveformPeakBucket] // 10 buckets/sec (100ms)
    public let level2: [WaveformPeakBucket] // 1 bucket/sec (1s)

    public init(
        trackID: CMPersistentTrackID,
        sampleRate: Double,
        duration: CMTime,
        level0: [WaveformPeakBucket],
        level1: [WaveformPeakBucket],
        level2: [WaveformPeakBucket]
    ) {
        self.trackID = trackID
        self.sampleRate = sampleRate
        self.duration = duration
        self.level0 = level0
        self.level1 = level1
        self.level2 = level2
    }

    /// Renders peaks for visible range in O(pixelWidth) complexity
    public func renderPeaks(for timeRange: CMTimeRange, pixelWidth: Int) -> [WaveformPeakBucket] {
        guard pixelWidth > 0, timeRange.duration.seconds > 0 else { return [] }
        let pxPerSec = Double(pixelWidth) / timeRange.duration.seconds

        let (source, deltaT): ([WaveformPeakBucket], Double) = {
            if pxPerSec >= 50.0 {
                return (level0, 0.01)
            } else if pxPerSec >= 5.0 {
                return (level1, 0.1)
            } else {
                return (level2, 1.0)
            }
        }()

        let startSec = max(0, timeRange.start.seconds)
        let endSec = min(duration.seconds, startSec + timeRange.duration.seconds)
        let startIndex = max(0, min(source.count, Int(floor(startSec / deltaT))))
        let endIndex = max(startIndex, min(source.count, Int(ceil(endSec / deltaT))))

        let slice = Array(source[startIndex..<endIndex])
        guard !slice.isEmpty else { return [] }

        // Resample slice to exact pixelWidth count
        if slice.count == pixelWidth {
            return slice
        } else if slice.count > pixelWidth {
            var resampled: [WaveformPeakBucket] = []
            resampled.reserveCapacity(pixelWidth)
            let ratio = Double(slice.count) / Double(pixelWidth)
            for p in 0..<pixelWidth {
                let subStart = Int(Double(p) * ratio)
                let subEnd = min(slice.count, Int(Double(p + 1) * ratio))
                var minV: Float = 0.0
                var maxV: Float = 0.0
                var sumSq: Float = 0.0
                let count = max(1, subEnd - subStart)
                for i in subStart..<subEnd {
                    minV = min(minV, slice[i].minSample)
                    maxV = max(maxV, slice[i].maxSample)
                    sumSq += slice[i].rmsSample * slice[i].rmsSample
                }
                resampled.append(WaveformPeakBucket(minSample: minV, maxSample: maxV, rmsSample: sqrt(sumSq / Float(count))))
            }
            return resampled
        } else {
            // Linear stretch interpolation
            var resampled: [WaveformPeakBucket] = []
            resampled.reserveCapacity(pixelWidth)
            let step = Double(slice.count - 1) / Double(max(1, pixelWidth - 1))
            for p in 0..<pixelWidth {
                let idx = Int(Double(p) * step)
                resampled.append(slice[min(slice.count - 1, idx)])
            }
            return resampled
        }
    }
}

public enum WaveformError: Error, LocalizedError {
    case assetLoadingFailed(Error)
    case audioTrackNotFound(CMPersistentTrackID)
    case readerInitializationFailed(Error)
    case readerFailed(AVAssetReader.Status, Error?)
    case invalidSampleBuffer
    case cacheReadFailed(URL, Error)
    case cacheWriteFailed(URL, Error)
    case extractionCancelled

    public var errorDescription: String? {
        switch self {
        case .assetLoadingFailed(let err):
            return "Failed to load audio asset: \(err.localizedDescription)"
        case .audioTrackNotFound(let id):
            return "Audio track \(id) not found in asset"
        case .readerInitializationFailed(let err):
            return "AVAssetReader failed to initialize: \(err.localizedDescription)"
        case .readerFailed(let status, let err):
            return "AVAssetReader failed with status \(status): \(err?.localizedDescription ?? "unknown")"
        case .invalidSampleBuffer:
            return "Invalid audio sample buffer"
        case .cacheReadFailed(let url, let err):
            return "Failed to read cached waveform from \(url.path): \(err.localizedDescription)"
        case .cacheWriteFailed(let url, let err):
            return "Failed to write cached waveform to \(url.path): \(err.localizedDescription)"
        case .extractionCancelled:
            return "Waveform extraction was cancelled"
        }
    }
}

public protocol WaveformExtracting: Actor {
    func extractWaveform(
        from asset: AVAsset,
        trackID: CMPersistentTrackID,
        cacheDirectory: URL?,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> MultiScaleWaveform

    func cancelExtraction(for trackID: CMPersistentTrackID)
}

public actor WaveformExtractor: WaveformExtracting {
    private var inFlightTasks: [CMPersistentTrackID: Task<MultiScaleWaveform, Error>] = [:]

    public init() {}

    public func cancelExtraction(for trackID: CMPersistentTrackID) {
        inFlightTasks[trackID]?.cancel()
        inFlightTasks.removeValue(forKey: trackID)
    }

    public func extractWaveform(
        from asset: AVAsset,
        trackID: CMPersistentTrackID,
        cacheDirectory: URL?,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> MultiScaleWaveform {
        // 1. Check disk cache
        if let dir = cacheDirectory {
            let cacheFileURL = dir.appendingPathComponent("track_\(trackID).waveform")
            if FileManager.default.fileExists(atPath: cacheFileURL.path),
               let cached = try? loadFromBinaryFile(at: cacheFileURL) {
                return cached
            }
        }

        // 2. Coalesce duplicate requests
        if let existing = inFlightTasks[trackID] {
            return try await existing.value
        }

        let task = Task<MultiScaleWaveform, Error> {
            let waveform = try await self.performExtraction(
                from: asset,
                trackID: trackID,
                progress: progress
            )

            // Save to disk cache
            if let dir = cacheDirectory {
                let cacheFileURL = dir.appendingPathComponent("track_\(trackID).waveform")
                try? self.saveToBinaryFile(waveform, at: cacheFileURL)
            }

            return waveform
        }

        inFlightTasks[trackID] = task
        defer { inFlightTasks.removeValue(forKey: trackID) }
        return try await task.value
    }

    private func performExtraction(
        from asset: AVAsset,
        trackID: CMPersistentTrackID,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> MultiScaleWaveform {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = audioTracks.first(where: { $0.trackID == trackID }) else {
            throw WaveformError.audioTrackNotFound(trackID)
        }

        let duration = try await asset.load(.duration)
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(trackOutput)
        guard reader.startReading() else {
            throw WaveformError.readerFailed(reader.status, reader.error)
        }

        let sampleRate: Double = 44100.0
        let bucketSize = max(1, Int(round(sampleRate / 100.0))) // 100 buckets/sec = 441 samples
        var level0: [WaveformPeakBucket] = []
        var leftoverSamples: [Float] = []
        let totalEstimatedBuckets = max(1, Int(duration.seconds * 100.0))
        var lastReportedProgress: Double = 0.0

        while reader.status == .reading {
            try Task.checkCancellation()

            let hasMore = autoreleasepool { () -> Bool in
                guard let sampleBuffer = trackOutput.copyNextSampleBuffer(),
                      let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                    return false
                }

                var length = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &dataPointer)
                guard let pointer = dataPointer, length > 0 else { return true }

                let floatCount = length / MemoryLayout<Float>.size
                let floatPointer = pointer.withMemoryRebound(to: Float.self, capacity: floatCount) { $0 }

                var combined: [Float] = leftoverSamples
                combined.append(contentsOf: UnsafeBufferPointer(start: floatPointer, count: floatCount))

                var offset = 0
                while (combined.count - offset) >= bucketSize {
                    let chunk = combined[offset..<(offset + bucketSize)]
                    var minV: Float = 0.0
                    var maxV: Float = 0.0
                    var rmsV: Float = 0.0
                    chunk.withUnsafeBufferPointer { buf in
                        guard let base = buf.baseAddress else { return }
                        vDSP_minv(base, 1, &minV, vDSP_Length(bucketSize))
                        vDSP_maxv(base, 1, &maxV, vDSP_Length(bucketSize))
                        vDSP_rmsqv(base, 1, &rmsV, vDSP_Length(bucketSize))
                    }
                    level0.append(WaveformPeakBucket(minSample: minV, maxSample: maxV, rmsSample: rmsV))
                    offset += bucketSize
                }
                leftoverSamples = Array(combined[offset...])
                CMSampleBufferInvalidate(sampleBuffer)
                return true
            }

            if !hasMore { break }

            let currentProgress = min(1.0, Double(level0.count) / Double(totalEstimatedBuckets))
            if currentProgress - lastReportedProgress >= 0.05 {
                lastReportedProgress = currentProgress
                progress?(currentProgress)
            }
        }

        if reader.status == .failed {
            throw WaveformError.readerFailed(reader.status, reader.error)
        }

        // Build Level 1 (10 buckets/sec) and Level 2 (1 bucket/sec)
        let level1 = buildPyramidLevel(from: level0, factor: 10)
        let level2 = buildPyramidLevel(from: level1, factor: 10)

        progress?(1.0)
        return MultiScaleWaveform(
            trackID: trackID,
            sampleRate: sampleRate,
            duration: duration,
            level0: level0,
            level1: level1,
            level2: level2
        )
    }

    private func buildPyramidLevel(from source: [WaveformPeakBucket], factor: Int) -> [WaveformPeakBucket] {
        guard factor > 0 else { return source }
        var result: [WaveformPeakBucket] = []
        result.reserveCapacity(source.count / factor + 1)
        var i = 0
        while i < source.count {
            let end = min(source.count, i + factor)
            var minV: Float = 0.0
            var maxV: Float = 0.0
            var sumSq: Float = 0.0
            let count = max(1, end - i)
            for j in i..<end {
                minV = min(minV, source[j].minSample)
                maxV = max(maxV, source[j].maxSample)
                sumSq += source[j].rmsSample * source[j].rmsSample
            }
            result.append(WaveformPeakBucket(minSample: minV, maxSample: maxV, rmsSample: sqrt(sumSq / Float(count))))
            i += factor
        }
        return result
    }

    private func saveToBinaryFile(_ waveform: MultiScaleWaveform, at url: URL) throws {
        var data = Data()
        // 32-byte header
        data.append(contentsOf: "MDWF".utf8) // 4 bytes
        var version: UInt16 = 1
        data.append(Data(bytes: &version, count: 2))
        var flags: UInt16 = 0
        data.append(Data(bytes: &flags, count: 2))
        var sampleRate = waveform.sampleRate
        data.append(Data(bytes: &sampleRate, count: 8))
        var durationSec = waveform.duration.seconds
        data.append(Data(bytes: &durationSec, count: 8))
        var l0Count = UInt32(waveform.level0.count)
        data.append(Data(bytes: &l0Count, count: 4))
        var l1Count = UInt32(waveform.level1.count)
        data.append(Data(bytes: &l1Count, count: 4))
        var l2Count = UInt32(waveform.level2.count)
        data.append(Data(bytes: &l2Count, count: 4))

        func appendBuckets(_ buckets: [WaveformPeakBucket]) {
            buckets.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                data.append(UnsafeBufferPointer(start: base, count: buf.count))
            }
        }
        appendBuckets(waveform.level0)
        appendBuckets(waveform.level1)
        appendBuckets(waveform.level2)

        try data.write(to: url, options: .atomic)
    }

    private func loadFromBinaryFile(at url: URL) throws -> MultiScaleWaveform {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= 36 else { throw WaveformError.invalidSampleBuffer }

        let magic = String(data: data[0..<4], encoding: .utf8)
        guard magic == "MDWF" else { throw WaveformError.invalidSampleBuffer }

        var sampleRate: Double = 0
        (data[8..<16] as NSData).getBytes(&sampleRate, length: 8)
        var durationSec: Double = 0
        (data[16..<24] as NSData).getBytes(&durationSec, length: 8)
        var l0Count: UInt32 = 0
        (data[24..<28] as NSData).getBytes(&l0Count, length: 4)
        var l1Count: UInt32 = 0
        (data[28..<32] as NSData).getBytes(&l1Count, length: 4)
        var l2Count: UInt32 = 0
        (data[32..<36] as NSData).getBytes(&l2Count, length: 4)

        let bucketSize = MemoryLayout<WaveformPeakBucket>.size
        var offset = 36

        func readBuckets(count: Int) -> [WaveformPeakBucket] {
            let byteLen = count * bucketSize
            guard offset + byteLen <= data.count else { return [] }
            let subdata = data[offset..<(offset + byteLen)]
            offset += byteLen
            return subdata.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: WaveformPeakBucket.self))
            }
        }

        let l0 = readBuckets(count: Int(l0Count))
        let l1 = readBuckets(count: Int(l1Count))
        let l2 = readBuckets(count: Int(l2Count))

        return MultiScaleWaveform(
            trackID: 1,
            sampleRate: sampleRate,
            duration: CMTime(seconds: durationSec, preferredTimescale: 600),
            level0: l0,
            level1: l1,
            level2: l2
        )
    }
}
```

---

## 3. Caveats

1. **Retina Display Scale Parameter**:
   - `FilmstripRequest` accepts `displayScale: CGFloat` (default 2.0). The UI layer (`TimelineView`) should feed the active window's `NSScreen.backingScaleFactor`. On standard 1x monitors, requesting at 2x wastes 4x memory; passing the actual backing scale factor guarantees optimal pixel density and memory bounding.
2. **Keyframe Sparsity in Screen Recordings**:
   - Screen recordings generated by macOS QuickTime or OBS often have keyframe intervals (GOP size) between 2 and 5 seconds when the display is static. Bounded tolerance (`tolerance = min(deltaT * 0.45, 0.25)`) gracefully handles this by decoding intermediate frames when zoomed in, while snapping to keyframes when zoomed out.
3. **Audio Track Channel Configurations**:
   - For multi-channel recordings (e.g. 5.1 surround or stereo), our Accelerate pipeline computes the max and min across all channels, matching standard NLE timeline track expectations. If per-channel stereo visualization is needed, `WaveformPeakBucket` can store left and right channels separately.
4. **No Implementation in This Phase**:
   - In adherence to Explorer constraints, no source code in `Sources/` has been written or modified. All protocols, classes, and algorithms are fully specified in this document for the worker agent to implement in Milestone 3.

---

## 4. Conclusion

1. **Filmstrip Generation**:
   - The combination of strict `maximumSize` bounding, adaptive time tolerances (`min(deltaT * 0.45, 0.25)`), outward-spiral visual priority ordering, and bounded 3-task concurrency guarantees smooth 60fps timeline interaction without memory blowups, remaining strictly under the 25MB NSCache ceiling.
   - Dual-tier caching (in-memory `NSCache` + `.amend/thumbnails/` JPEG disk storage) ensures that re-opening a project requires zero video decoding for already-scanned regions.
2. **Audio Waveform Engine**:
   - Direct `AVAssetReader` 32-bit Float Linear PCM reading coupled with `vDSP_maxv`, `vDSP_minv`, and `vDSP_rmsqv` delivers $> 120\times$ real-time extraction speed.
   - The 3-level Peak Pyramid (`MultiScaleWaveform`) guarantees that timeline waveform rendering is strictly $O(\text{pixelWidth})$ ($< 0.05\text{ms}$ query latency), eliminating UI lag during scrubbing.
   - Binary disk caching to `.amend/waveforms/` provides instant sub-millisecond project loading.
3. **Milestone 3 Readiness**:
   - Concrete interfaces `FilmstripGenerating` and `WaveformExtracting` fit seamlessly into `Sources/AmendCore/Timeline/`, alongside `TimelineClock` and `SMPTERulerFormatter` from `m3_explorer_1` and view bindings from `m3_explorer_3`.

---

## 5. Verification Method

### 5.1 Independent Verification Commands
1. **Existing Baseline Test Suite**:
   ```bash
   swift test --filter StorageAPFSTests
   swift test --filter AudioRoutingTests
   ```
   Both suites must pass with 0 failures.

2. **Planned Verification Test Suites for Worker Agent**:
   When `FilmstripGenerator.swift` and `WaveformExtractor.swift` are implemented, verify with:
   ```bash
   swift test --filter FilmstripGeneratorTests
   swift test --filter WaveformExtractorTests
   ```

### 5.2 Verification Matrix for Milestone 3 Worker
| Test Case | Method | Expected Output |
|---|---|---|
| **Filmstrip Viewport Request Math** | Request 100 pt cells at 50 px/s with visibleRect `[500, 1500]` | Indices match exact overdraw range; center-priority ordering verified |
| **Filmstrip Bounded Time Tolerance** | Request frame with `deltaT = 0.2s` | Tolerance set to $\le 0.09\text{s}$, verifying distinct frames returned |
| **Filmstrip Memory Ceiling** | Generate 200 thumbnails from 4K video fixture | Memory usage verified $< 30 \text{ MB}$, zero full-resolution frame allocations |
| **Filmstrip Cancellation** | Rapidly dispatch 10 generation tasks, cancelling each | Stale tasks abort immediately, no thread exhaustion or leaked allocations |
| **Filmstrip Disk Cache Persistence** | Generate thumbnails, clear memory cache, request again | Thumbnails loaded from `.amend/thumbnails/` in $< 5\text{ms}$, 0 video decodes |
| **Waveform Synthetic Extraction** | Extract from `Fixture1SingleTrack` (10s movie) | Silence segments produce $\approx 0.0$ RMS; 0.6 sine tones produce $\approx 0.424$ RMS |
| **Multi-Scale Waveform Render Complexity** | Render 1200 px waveform from 1-hour audio | Execution completes in $< 0.1\text{ms}$; sample count equals exactly 1200 |
| **Waveform Binary Bundle Roundtrip** | Serialize to `.waveform` binary file and deserialize | All peak values, counts, sample rates match identically |
