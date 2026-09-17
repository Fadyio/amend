import Foundation
import AVFoundation
import CoreMedia

/// Extracts uncompressed PCM audio from a specific audio track of an AVAsset.
public struct AudioTrackExtractor: Sendable {
    public init() {}

    /// Extracts PCM audio from the designated track ID of an asset.
    /// Resamples to target format (e.g. 16kHz Float32 mono for ASR/VAD, or 44.1kHz Float32 for playback/editing).
    public func extractPCMBuffer(
        from asset: AVAsset,
        trackID: CMPersistentTrackID,
        targetSampleRate: Double = 16000.0,
        targetChannels: AVAudioChannelCount = 1
    ) async throws -> AVAudioPCMBuffer {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = audioTracks.first(where: { $0.trackID == trackID }) else {
            throw AudioTrackInspectorError.designatedTrackNotInAsset(Int(trackID))
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: targetChannels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOutput) else {
            throw AudioTrackInspectorError.unreadableAsset(URL(fileURLWithPath: ""), "Cannot add track output for track \(trackID)")
        }
        reader.add(trackOutput)
        guard reader.startReading() else {
            throw AudioTrackInspectorError.unreadableAsset(URL(fileURLWithPath: ""), reader.error?.localizedDescription ?? "Failed to start reading")
        }

        var sampleData = Data()
        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var bufferData = Data(count: length)
            bufferData.withUnsafeMutableBytes { rawBytes in
                _ = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: rawBytes.baseAddress!)
            }
            sampleData.append(bufferData)
        }

        if reader.status == .failed {
            throw AudioTrackInspectorError.unreadableAsset(URL(fileURLWithPath: ""), reader.error?.localizedDescription ?? "Reader failed")
        }

        let bytesPerFrame = Int(targetChannels) * MemoryLayout<Float>.size
        let frameCount = AVAudioFrameCount(sampleData.count / bytesPerFrame)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: targetSampleRate, channels: targetChannels),
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(1, frameCount)) else {
            throw AudioTrackInspectorError.unreadableAsset(URL(fileURLWithPath: ""), "Failed to allocate PCM buffer")
        }

        pcmBuffer.frameLength = frameCount
        if frameCount > 0 {
            sampleData.withUnsafeBytes { rawPtr in
                if let floatPtr = rawPtr.baseAddress?.assumingMemoryBound(to: Float.self) {
                    pcmBuffer.floatChannelData?[0].update(from: floatPtr, count: Int(frameCount))
                }
            }
        }

        return pcmBuffer
    }
}
