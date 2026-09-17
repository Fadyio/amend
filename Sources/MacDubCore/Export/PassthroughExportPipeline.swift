import Foundation
import CoreMedia
@preconcurrency import AVFoundation

public struct PassthroughExportConfig: Sendable {
    public let sourceURL: URL
    public let destinationURL: URL
    public let designatedNarrationTrackID: CMPersistentTrackID
    public let passthroughTrackIDs: [CMPersistentTrackID]
    public let cues: [Cue]
    public let bundleRootURL: URL?

    public init(
        sourceURL: URL,
        destinationURL: URL,
        designatedNarrationTrackID: CMPersistentTrackID,
        passthroughTrackIDs: [CMPersistentTrackID] = [],
        cues: [Cue] = [],
        bundleRootURL: URL? = nil
    ) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.designatedNarrationTrackID = designatedNarrationTrackID
        self.passthroughTrackIDs = passthroughTrackIDs
        self.cues = cues
        self.bundleRootURL = bundleRootURL
    }
}

public struct ExportResult: Sendable {
    public let outputURL: URL
    public let duration: CMTime
    public let videoSampleCount: Int
    public let wasVideoReencoded: Bool

    public init(
        outputURL: URL,
        duration: CMTime,
        videoSampleCount: Int,
        wasVideoReencoded: Bool
    ) {
        self.outputURL = outputURL
        self.duration = duration
        self.videoSampleCount = videoSampleCount
        self.wasVideoReencoded = wasVideoReencoded
    }
}

public enum ExportError: Error, LocalizedError {
    case noVideoTrackFound
    case readerInitFailed(Error)
    case writerInitFailed(Error)
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noVideoTrackFound: return "No video track found in source media"
        case .readerInitFailed(let err): return "AVAssetReader failed: \(err.localizedDescription)"
        case .writerInitFailed(let err): return "AVAssetWriter failed: \(err.localizedDescription)"
        case .exportFailed(let reason): return "Export failed: \(reason)"
        }
    }
}

public protocol ExportPipelining: Sendable {
    func export(
        config: PassthroughExportConfig,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> ExportResult
}

public final class PassthroughExportPipeline: ExportPipelining, @unchecked Sendable {
    public init() {}

    public func export(
        config: PassthroughExportConfig,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ExportResult {
        // Ensure destination folder exists and delete existing output file
        let destURL = config.destinationURL
        let parentDir = destURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }

        let asset = AVURLAsset(url: config.sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let totalDuration = try await asset.load(.duration)

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideoTrack = videoTracks.first else {
            throw ExportError.noVideoTrackFound
        }
        let allAudioTracks = try await asset.loadTracks(withMediaType: .audio)

        let fileType: AVFileType = destURL.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destURL, fileType: fileType)

        // 1. Configure Compressed Video Passthrough (outputSettings: nil -> ZERO re-encoding, ADR-0008)
        let videoOutput = AVAssetReaderTrackOutput(track: sourceVideoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        let videoFormatDescs = try await sourceVideoTrack.load(.formatDescriptions)
        guard let videoFormatHint = videoFormatDescs.first else {
            throw ExportError.exportFailed("Missing video format description")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormatHint)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw ExportError.exportFailed("Cannot add video input to writer")
        }
        writer.add(videoInput)

        // 2. Configure Audio Tracks (Passthrough tracks + Narration track)
        struct AudioTrackPair {
            let output: AVAssetReaderTrackOutput
            let input: AVAssetWriterInput
        }
        var audioPairs: [AudioTrackPair] = []

        for audioTrack in allAudioTracks {
            let audioFormatDescs = try await audioTrack.load(.formatDescriptions)
            guard let audioFormatHint = audioFormatDescs.first else { continue }

            // If this is a passthrough track OR an unedited narration track:
            // Use compressed sample passthrough!
            let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            audioOutput.alwaysCopiesSampleData = false
            reader.add(audioOutput)

            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormatHint)
            audioInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(audioInput) else { continue }
            writer.add(audioInput)

            audioPairs.append(AudioTrackPair(output: audioOutput, input: audioInput))
        }

        // 3. Start Session
        guard reader.startReading() else {
            throw ExportError.readerInitFailed(reader.error ?? NSError(domain: "Export", code: 1))
        }
        guard writer.startWriting() else {
            throw ExportError.writerInitFailed(writer.error ?? NSError(domain: "Export", code: 2))
        }
        writer.startSession(atSourceTime: .zero)

        // 4. Non-Blocking Multi-Track Interleaving Remux Loop
        var videoFinished = false
        var audioFinished = audioPairs.map { _ in false }
        var videoSampleCount = 0
        let totalDurationSec = max(0.1, CMTimeGetSeconds(totalDuration))

        while !videoFinished || audioFinished.contains(false) {
            var progressMade = false

            // Try copy next video sample buffer
            if !videoFinished && videoInput.isReadyForMoreMediaData {
                if let sampleBuffer = videoOutput.copyNextSampleBuffer() {
                    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let success = videoInput.append(sampleBuffer)
                    if !success {
                        throw ExportError.exportFailed(writer.error?.localizedDescription ?? "Failed to append video sample buffer")
                    }
                    videoSampleCount += 1
                    progressMade = true

                    let currentSec = CMTimeGetSeconds(pts)
                    progress?(min(0.99, currentSec / totalDurationSec))
                } else {
                    videoFinished = true
                    videoInput.markAsFinished()
                }
            }

            // Try copy next audio sample buffer for each audio track
            for i in 0..<audioPairs.count {
                if audioFinished[i] { continue }
                let pair = audioPairs[i]
                if pair.input.isReadyForMoreMediaData {
                    if let sampleBuffer = pair.output.copyNextSampleBuffer() {
                        let success = pair.input.append(sampleBuffer)
                        if !success {
                            throw ExportError.exportFailed(writer.error?.localizedDescription ?? "Failed to append audio sample buffer")
                        }
                        progressMade = true
                    } else {
                        audioFinished[i] = true
                        pair.input.markAsFinished()
                    }
                }
            }

            if !progressMade {
                try await Task.sleep(nanoseconds: 500_000) // 0.5ms sleep to yield to background writer thread
            }
        }

        // 5. Finalize Writing
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        guard writer.status == .completed else {
            throw ExportError.exportFailed(writer.error?.localizedDescription ?? "Writer failed with status \(writer.status.rawValue)")
        }

        progress?(1.0)

        return ExportResult(
            outputURL: destURL,
            duration: totalDuration,
            videoSampleCount: videoSampleCount,
            wasVideoReencoded: false // Guaranteed bitstream identity by outputSettings: nil
        )
    }
}
