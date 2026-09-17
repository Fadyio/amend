import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import AudioToolbox
import MacDubCore

public enum AudioSegmentSpec: Sendable, Equatable {
    case silence(duration: CMTime)
    case sineTone(frequency: Double, amplitude: Float = 0.5, duration: CMTime)
    case noise(amplitude: Float = 0.1, duration: CMTime)

    public var duration: CMTime {
        switch self {
        case .silence(let duration): return duration
        case .sineTone(_, _, let duration): return duration
        case .noise(_, let duration): return duration
        }
    }
}

public struct SyntheticAudioTrackSpec: Sendable {
    public let trackName: String
    public let segments: [AudioSegmentSpec]
    public let sampleRate: Double
    public let channels: Int

    public init(
        trackName: String,
        segments: [AudioSegmentSpec],
        sampleRate: Double = 44100.0,
        channels: Int = 1
    ) {
        self.trackName = trackName
        self.segments = segments
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public var totalDuration: CMTime {
        var total = CMTime.zero
        for seg in segments {
            total = CMTimeAdd(total, seg.duration)
        }
        return total
    }
}

public struct SyntheticAsset: Sendable {
    public let fileURL: URL
    public let duration: CMTime
    public let videoTrackID: CMPersistentTrackID?
    public let audioTrackIDs: [CMPersistentTrackID]
    public let expectedCues: [Cue]
    public let roomToneRange: CMTimeRange?

    public init(
        fileURL: URL,
        duration: CMTime,
        videoTrackID: CMPersistentTrackID?,
        audioTrackIDs: [CMPersistentTrackID],
        expectedCues: [Cue] = [],
        roomToneRange: CMTimeRange? = nil
    ) {
        self.fileURL = fileURL
        self.duration = duration
        self.videoTrackID = videoTrackID
        self.audioTrackIDs = audioTrackIDs
        self.expectedCues = expectedCues
        self.roomToneRange = roomToneRange
    }
}

private struct PreparedAudioTrack {
    let input: AVAssetWriterInput
    let spec: SyntheticAudioTrackSpec
    let formatDesc: CMAudioFormatDescription
    let pcmSamples: [Int16]
}

public enum SyntheticFixtureGenerator {

    public static func createMovie(
        at fileURL: URL,
        duration: CMTime,
        fps: Int32 = 30,
        videoSize: CGSize = CGSize(width: 640, height: 360),
        audioTracks: [SyntheticAudioTrackSpec] = [],
        expectedCues: [Cue] = [],
        roomToneRange: CMTimeRange? = nil
    ) async throws -> SyntheticAsset {
        // Ensure destination folder exists and delete existing file
        let parentDir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }

        let assetWriter = try AVAssetWriter(outputURL: fileURL, fileType: .mov)

        // 1. Setup Video Writer Input
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(videoSize.width),
            AVVideoHeightKey: Int(videoSize.height)
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: Int(videoSize.width),
            kCVPixelBufferHeightKey as String: Int(videoSize.height)
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        guard assetWriter.canAdd(videoInput) else {
            throw NSError(domain: "SyntheticFixtureGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot add video input"])
        }
        assetWriter.add(videoInput)

        // 2. Setup and Pre-Synthesize Audio Inputs
        var preparedTracks: [PreparedAudioTrack] = []
        for trackSpec in audioTracks {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: trackSpec.sampleRate,
                AVNumberOfChannelsKey: trackSpec.channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = false
            guard assetWriter.canAdd(audioInput) else {
                throw NSError(domain: "SyntheticFixtureGenerator", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot add audio input for track \(trackSpec.trackName)"])
            }
            assetWriter.add(audioInput)

            // Format Description
            var asbd = AudioStreamBasicDescription(
                mSampleRate: trackSpec.sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(trackSpec.channels * 2),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(trackSpec.channels * 2),
                mChannelsPerFrame: UInt32(trackSpec.channels),
                mBitsPerChannel: 16,
                mReserved: 0
            )
            var formatDescription: CMAudioFormatDescription?
            let descStatus = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            )
            guard descStatus == noErr, let formatDesc = formatDescription else {
                throw NSError(domain: "SyntheticFixtureGenerator", code: 10, userInfo: [NSLocalizedDescriptionKey: "CMAudioFormatDescriptionCreate failed"])
            }

            // Pre-synthesize entire track audio samples
            let samples = synthesizeAudioData(for: trackSpec, targetDuration: duration)
            preparedTracks.append(PreparedAudioTrack(input: audioInput, spec: trackSpec, formatDesc: formatDesc, pcmSamples: samples))
        }

        // 3. Start Session
        guard assetWriter.startWriting() else {
            throw assetWriter.error ?? NSError(domain: "SyntheticFixtureGenerator", code: 3, userInfo: [NSLocalizedDescriptionKey: "startWriting failed"])
        }
        assetWriter.startSession(atSourceTime: .zero)

        // 4. Interleaved Writing of Video Frames and Audio Samples
        let totalSeconds = CMTimeGetSeconds(duration)
        let totalFrames = Int(ceil(totalSeconds * Double(fps)))
        let width = Int(videoSize.width)
        let height = Int(videoSize.height)

        var frameIndex = 0
        var trackSampleIndices = Array(repeating: 0, count: preparedTracks.count)
        var videoFinished = totalFrames == 0
        var audioFinished = preparedTracks.map { _ in false }

        if videoFinished {
            videoInput.markAsFinished()
        }

        while !videoFinished || audioFinished.contains(false) {
            var progressMade = false

            // 1. Try write video if ready
            if !videoFinished && videoInput.isReadyForMoreMediaData {
                guard let pixelBuffer = createPixelBuffer(width: width, height: height, frameIndex: frameIndex, totalFrames: totalFrames) else {
                    throw NSError(domain: "SyntheticFixtureGenerator", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create pixel buffer"])
                }

                let framePTS = CMTime(value: Int64(frameIndex), timescale: fps)
                guard adaptor.append(pixelBuffer, withPresentationTime: framePTS) else {
                    throw assetWriter.error ?? NSError(domain: "SyntheticFixtureGenerator", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to append pixel buffer at frame \(frameIndex)"])
                }

                frameIndex += 1
                progressMade = true
                if frameIndex >= totalFrames {
                    videoFinished = true
                    videoInput.markAsFinished()
                }
            }

            // 2. Try write audio tracks if ready
            for i in 0..<preparedTracks.count {
                if audioFinished[i] { continue }
                let track = preparedTracks[i]
                let sampleRate = track.spec.sampleRate
                let channels = track.spec.channels
                let totalTrackSamples = track.pcmSamples.count / channels

                if trackSampleIndices[i] >= totalTrackSamples {
                    audioFinished[i] = true
                    track.input.markAsFinished()
                    continue
                }

                if track.input.isReadyForMoreMediaData {
                    let startSample = trackSampleIndices[i]
                    // Chunk size: ~0.1s (e.g. 4410 samples) or remaining
                    let chunkSize = min(Int(round(sampleRate * 0.1)), totalTrackSamples - startSample)
                    let endSample = startSample + chunkSize
                    let sliceFrameCount = chunkSize
                    let startIndex = startSample * channels
                    let endIndex = endSample * channels
                    let sliceData = Array(track.pcmSamples[startIndex..<endIndex])

                    let pts = CMTime(value: Int64(startSample), timescale: Int32(sampleRate))
                    guard let sBuf = makeSampleBuffer(pcmData: sliceData, formatDesc: track.formatDesc, sampleCount: sliceFrameCount, pts: pts) else {
                        throw NSError(domain: "SyntheticFixtureGenerator", code: 11, userInfo: [NSLocalizedDescriptionKey: "makeSampleBuffer failed"])
                    }

                    guard track.input.append(sBuf) else {
                        throw assetWriter.error ?? NSError(domain: "SyntheticFixtureGenerator", code: 12, userInfo: [NSLocalizedDescriptionKey: "audio append failed"])
                    }

                    trackSampleIndices[i] = endSample
                    progressMade = true
                    if trackSampleIndices[i] >= totalTrackSamples {
                        audioFinished[i] = true
                        track.input.markAsFinished()
                    }
                }
            }

            if !progressMade {
                try await Task.sleep(nanoseconds: 500_000) // 0.5ms
            }
        }

        // 5. Finish Writing
        await withCheckedContinuation { continuation in
            assetWriter.finishWriting {
                continuation.resume()
            }
        }

        guard assetWriter.status == .completed else {
            throw assetWriter.error ?? NSError(domain: "SyntheticFixtureGenerator", code: 6, userInfo: [NSLocalizedDescriptionKey: "finishWriting failed with status \(assetWriter.status.rawValue)"])
        }

        // 6. Inspect resulting asset for track IDs
        let avAsset = AVURLAsset(url: fileURL)
        let videoTracks = try await avAsset.loadTracks(withMediaType: .video)
        let audioTracksFound = try await avAsset.loadTracks(withMediaType: .audio)

        let videoTrackID = videoTracks.first?.trackID
        let audioTrackIDs = audioTracksFound.map { $0.trackID }

        return SyntheticAsset(
            fileURL: fileURL,
            duration: duration,
            videoTrackID: videoTrackID,
            audioTrackIDs: audioTrackIDs,
            expectedCues: expectedCues,
            roomToneRange: roomToneRange
        )
    }

    // MARK: - Pixel Buffer Creation

    private static func createPixelBuffer(width: Int, height: Int, frameIndex: Int, totalFrames: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            return nil
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let progress = totalFrames > 0 ? Float(frameIndex) / Float(totalFrames) : 0.0

        // Background color cycling from dark blue to cyan
        let blueByte = UInt8(clamping: Int(180 + 75 * sin(progress * .pi)))
        let greenByte = UInt8(clamping: Int(40 + 100 * progress))
        let redByte = UInt8(clamping: Int(20 + 40 * (1.0 - progress)))
        let alphaByte: UInt8 = 255

        for y in 0..<height {
            let rowPtr = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let pixelOffset = x * 4
                // BGRA format
                rowPtr[pixelOffset + 0] = blueByte
                rowPtr[pixelOffset + 1] = greenByte
                rowPtr[pixelOffset + 2] = redByte
                rowPtr[pixelOffset + 3] = alphaByte
            }
        }

        return buffer
    }

    // MARK: - Audio Pre-Synthesis

    private static func synthesizeAudioData(for spec: SyntheticAudioTrackSpec, targetDuration: CMTime) -> [Int16] {
        let sampleRate = spec.sampleRate
        let channels = spec.channels
        let totalSeconds = CMTimeGetSeconds(targetDuration)
        let totalTargetSamples = Int(round(totalSeconds * sampleRate))

        var allSamples: [Int16] = []
        allSamples.reserveCapacity(totalTargetSamples * channels)

        var currentSampleCount = 0

        for segment in spec.segments {
            let segSeconds = CMTimeGetSeconds(segment.duration)
            let segSamples = Int(round(segSeconds * sampleRate))
            if segSamples <= 0 { continue }

            switch segment {
            case .silence:
                allSamples.append(contentsOf: repeatElement(0, count: segSamples * channels))

            case .sineTone(let freq, let amp, _):
                let twoPi = 2.0 * Double.pi
                for i in 0..<segSamples {
                    let t = Double(currentSampleCount + i) / sampleRate
                    let val = Float(sin(twoPi * freq * t)) * amp
                    let int16Val = Int16(clamping: Int(val * 32767.0))
                    for _ in 0..<channels {
                        allSamples.append(int16Val)
                    }
                }

            case .noise(let amp, _):
                for _ in 0..<segSamples {
                    let randFloat = Float.random(in: -1.0...1.0) * amp
                    let int16Val = Int16(clamping: Int(randFloat * 32767.0))
                    for _ in 0..<channels {
                        allSamples.append(int16Val)
                    }
                }
            }
            currentSampleCount += segSamples
        }

        // Pad with silence if segments total less than targetDuration
        let currentFrames = allSamples.count / channels
        if currentFrames < totalTargetSamples {
            let missing = (totalTargetSamples - currentFrames) * channels
            allSamples.append(contentsOf: repeatElement(0, count: missing))
        }

        return allSamples
    }

    private static func makeSampleBuffer(
        pcmData: [Int16],
        formatDesc: CMAudioFormatDescription,
        sampleCount: Int,
        pts: CMTime
    ) -> CMSampleBuffer? {
        let byteCount = pcmData.count * MemoryLayout<Int16>.size
        var blockBuffer: CMBlockBuffer?

        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let bBuf = blockBuffer else {
            return nil
        }

        let replaceStatus = pcmData.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let base = rawBuffer.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: bBuf,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else {
            return nil
        }

        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: bBuf,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(sampleCount),
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr else {
            return nil
        }
        return sampleBuffer
    }

    // MARK: - Standalone Audio Buffer & File Synthesis

    public static func createPCMBuffer(
        duration: CMTime,
        frequency: Double = 440.0,
        amplitude: Float = 0.5,
        sampleRate: Double = 44100.0
    ) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw NSError(domain: "SyntheticFixtureGenerator", code: 20, userInfo: [NSLocalizedDescriptionKey: "Invalid standard format"])
        }

        let frameCount = AVAudioFrameCount(round(CMTimeGetSeconds(duration) * sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "SyntheticFixtureGenerator", code: 21, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate AVAudioPCMBuffer"])
        }
        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData?[0] else {
            throw NSError(domain: "SyntheticFixtureGenerator", code: 22, userInfo: [NSLocalizedDescriptionKey: "floatChannelData unavailable"])
        }

        let twoPi = 2.0 * Double.pi
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            channelData[i] = Float(sin(twoPi * frequency * t)) * amplitude
        }

        return buffer
    }

    public static func writeWAVFile(
        buffer: AVAudioPCMBuffer,
        to destinationURL: URL
    ) throws {
        let parentDir = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        let audioFile = try AVAudioFile(
            forWriting: destinationURL,
            settings: buffer.format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try audioFile.write(from: buffer)
    }
}
