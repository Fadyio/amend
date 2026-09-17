import Foundation
import AVFoundation
import Accelerate
import CoreMedia

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
        let durationSec = CMTimeGetSeconds(duration)
        guard pixelWidth > 0, timeRange.duration.isValid, !timeRange.duration.isIndefinite, CMTimeGetSeconds(timeRange.duration) > 0, durationSec > 0 else {
            return []
        }
        let rangeSec = CMTimeGetSeconds(timeRange.duration)
        let pxPerSec = Double(pixelWidth) / rangeSec

        let (source, deltaT): ([WaveformPeakBucket], Double) = {
            if pxPerSec >= 50.0 {
                return (level0, 0.01)
            } else if pxPerSec >= 5.0 {
                return (level1, 0.1)
            } else {
                return (level2, 1.0)
            }
        }()

        guard !source.isEmpty else { return [] }

        let startSec = max(0.0, CMTimeGetSeconds(timeRange.start))
        let endSec = min(durationSec, startSec + rangeSec)
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
               let cached = try? loadFromBinaryFile(at: cacheFileURL, trackID: trackID) {
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
        guard let track = audioTracks.first(where: { $0.trackID == trackID }) ?? audioTracks.first else {
            throw WaveformError.audioTrackNotFound(trackID)
        }

        let actualTrackID = track.trackID
        let duration = try await asset.load(.duration)

        let formatDescriptions = try await track.load(.formatDescriptions)
        var sampleRate: Double = 44100.0
        var channelCount: Int = 1
        if let firstDesc = formatDescriptions.first {
            let basicDesc = CMAudioFormatDescriptionGetStreamBasicDescription(firstDesc)
            if let asbd = basicDesc?.pointee {
                if asbd.mSampleRate > 0 {
                    sampleRate = asbd.mSampleRate
                }
                if asbd.mChannelsPerFrame > 0 {
                    channelCount = Int(asbd.mChannelsPerFrame)
                }
            }
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)
        guard reader.startReading() else {
            throw WaveformError.readerFailed(reader.status, reader.error)
        }

        let samplesPerBucket = max(1, Int(round(sampleRate / 100.0))) // 100 buckets/sec (10ms)
        let floatsPerBucket = samplesPerBucket * channelCount
        var level0: [WaveformPeakBucket] = []
        var leftoverSamples: [Float] = []
        let durationSec = max(0.1, CMTimeGetSeconds(duration))
        let totalEstimatedBuckets = max(1, Int(durationSec * 100.0))
        var lastReportedProgress: Double = 0.0

        while reader.status == .reading {
            try Task.checkCancellation()

            let hasMore = autoreleasepool { () -> Bool in
                guard let sampleBuffer = trackOutput.copyNextSampleBuffer() else {
                    return false
                }
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                    CMSampleBufferInvalidate(sampleBuffer)
                    return true
                }

                var length = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &dataPointer)
                guard let pointer = dataPointer, length > 0 else {
                    CMSampleBufferInvalidate(sampleBuffer)
                    return true
                }

                let floatCount = length / MemoryLayout<Float>.size
                let floatPointer = pointer.withMemoryRebound(to: Float.self, capacity: floatCount) { $0 }

                var combined: [Float] = leftoverSamples
                combined.append(contentsOf: UnsafeBufferPointer(start: floatPointer, count: floatCount))

                var offset = 0
                while (combined.count - offset) >= floatsPerBucket {
                    let chunk = combined[offset..<(offset + floatsPerBucket)]
                    var minV: Float = 0.0
                    var maxV: Float = 0.0
                    var rmsV: Float = 0.0
                    chunk.withUnsafeBufferPointer { buf in
                        guard let base = buf.baseAddress else { return }
                        vDSP_minv(base, 1, &minV, vDSP_Length(floatsPerBucket))
                        vDSP_maxv(base, 1, &maxV, vDSP_Length(floatsPerBucket))
                        vDSP_rmsqv(base, 1, &rmsV, vDSP_Length(floatsPerBucket))
                    }
                    level0.append(WaveformPeakBucket(minSample: minV, maxSample: maxV, rmsSample: rmsV))
                    offset += floatsPerBucket
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

        // Process leftover samples if any
        if !leftoverSamples.isEmpty {
            var minV: Float = 0.0
            var maxV: Float = 0.0
            var rmsV: Float = 0.0
            leftoverSamples.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                vDSP_minv(base, 1, &minV, vDSP_Length(buf.count))
                vDSP_maxv(base, 1, &maxV, vDSP_Length(buf.count))
                vDSP_rmsqv(base, 1, &rmsV, vDSP_Length(buf.count))
            }
            level0.append(WaveformPeakBucket(minSample: minV, maxSample: maxV, rmsSample: rmsV))
        }

        // Build Level 1 (10 buckets/sec) and Level 2 (1 bucket/sec)
        let level1 = buildPyramidLevel(from: level0, factor: 10)
        let level2 = buildPyramidLevel(from: level1, factor: 10)

        progress?(1.0)
        return MultiScaleWaveform(
            trackID: actualTrackID,
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

    public func saveToBinaryFile(_ waveform: MultiScaleWaveform, at url: URL) throws {
        var data = Data()
        // 32-byte header
        data.append(contentsOf: "MDWF".utf8) // 4 bytes
        var version: UInt16 = 1
        data.append(Data(bytes: &version, count: 2))
        var flags: UInt16 = 0
        data.append(Data(bytes: &flags, count: 2))
        var sampleRate = waveform.sampleRate
        data.append(Data(bytes: &sampleRate, count: 8))
        var durationSec = CMTimeGetSeconds(waveform.duration)
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
                let byteCount = buf.count * MemoryLayout<WaveformPeakBucket>.size
                data.append(UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self), count: byteCount)
            }
        }
        appendBuckets(waveform.level0)
        appendBuckets(waveform.level1)
        appendBuckets(waveform.level2)

        let parentDir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func loadFromBinaryFile(at url: URL, trackID: CMPersistentTrackID) throws -> MultiScaleWaveform {
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
            trackID: trackID,
            sampleRate: sampleRate,
            duration: CMTime(seconds: durationSec, preferredTimescale: 600_000),
            level0: l0,
            level1: l1,
            level2: l2
        )
    }
}
