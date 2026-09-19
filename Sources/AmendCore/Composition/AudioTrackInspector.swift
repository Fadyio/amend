import Foundation
import AVFoundation
import CoreMedia

/// Result of inspecting the audio tracks within a media asset.
public enum AudioTrackInspectionResult: Equatable, Sendable {
    case singleTrack(track: AudioTrackInfo, mapping: AudioTrackMapping)
    case multiTrack(tracks: [AudioTrackInfo], defaultMapping: AudioTrackMapping)
    case noAudioTracks
}

/// Errors that may occur during audio track inspection and validation.
public enum AudioTrackInspectorError: Error, LocalizedError, Equatable, Sendable {
    case fileNotFound(URL)
    case unreadableAsset(URL, String)
    case noAudioTracksFound(URL)
    case designatedTrackNotInAsset(Int)
    case passthroughTrackNotInAsset(Int)
    case narrationInPassthroughList(Int)
    case duplicatePassthroughTrackIDs([Int])
    case singleTrackAdvisoryViolation(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "Audio source file not found at: \(url.path)"
        case .unreadableAsset(let url, let message):
            return "Unable to read media asset at \(url.path): \(message)"
        case .noAudioTracksFound(let url):
            return "No audio tracks were found in media asset at: \(url.path)"
        case .designatedTrackNotInAsset(let id):
            return "Designated narration track ID \(id) is not present in the media asset."
        case .passthroughTrackNotInAsset(let id):
            return "Passthrough track ID \(id) is not present in the media asset."
        case .narrationInPassthroughList(let id):
            return "Track ID \(id) cannot be simultaneously designated as Narration and Passthrough."
        case .duplicatePassthroughTrackIDs(let ids):
            return "Duplicate passthrough track IDs specified: \(ids)"
        case .singleTrackAdvisoryViolation(let reason):
            return "Single-track advisory violation: \(reason)"
        }
    }
}

/// Inspects AVFoundation assets to discover audio tracks and validate track routing.
public struct AudioTrackInspector: Sendable {
    public init() {}

    /// Inspects the audio tracks in the media asset at the given URL.
    public func inspect(assetURL: URL) async throws -> AudioTrackInspectionResult {
        guard FileManager.default.fileExists(atPath: assetURL.path) else {
            throw AudioTrackInspectorError.fileNotFound(assetURL)
        }
        let asset = AVURLAsset(url: assetURL)
        return try await inspect(asset: asset)
    }

    /// Inspects the audio tracks in an AVAsset.
    public func inspect(asset: AVAsset) async throws -> AudioTrackInspectionResult {
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            let path = (asset as? AVURLAsset)?.url.path ?? "unknown"
            throw AudioTrackInspectorError.unreadableAsset(
                (asset as? AVURLAsset)?.url ?? URL(fileURLWithPath: path),
                error.localizedDescription
            )
        }

        if tracks.isEmpty {
            return .noAudioTracks
        }

        var trackInfos: [AudioTrackInfo] = []
        for track in tracks {
            let trackID = Int(track.trackID)
            let timeRange = try await track.load(.timeRange)
            let formatDescriptions = try await track.load(.formatDescriptions)
            let language = try? await track.load(.extendedLanguageTag)
            let dataRate = (try? await track.load(.estimatedDataRate)) ?? 0.0

            var formatString = "unknown"
            var channelCount = 2
            var sampleRate = 48000.0
            var bitDepth: Int? = nil

            if let firstDesc = formatDescriptions.first {
                let audioDesc = firstDesc as CMAudioFormatDescription
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioDesc)?.pointee {
                    formatString = fourCharCodeToString(asbd.mFormatID)
                    channelCount = Int(asbd.mChannelsPerFrame)
                    sampleRate = asbd.mSampleRate
                    if asbd.mBitsPerChannel > 0 {
                        bitDepth = Int(asbd.mBitsPerChannel)
                    }
                }
            }

            let info = AudioTrackInfo(
                id: trackID,
                format: formatString,
                channelCount: channelCount,
                sampleRate: sampleRate,
                bitDepth: bitDepth,
                duration: timeRange.duration,
                timeRange: timeRange,
                languageCode: language,
                title: nil,
                estimatedDataRate: dataRate
            )
            trackInfos.append(info)
        }

        if trackInfos.count == 1 {
            let single = trackInfos[0]
            let mapping = AudioTrackMapping.singleTrack(trackID: single.id)
            return .singleTrack(track: single, mapping: mapping)
        } else {
            let narrationID = trackInfos[0].id
            let passthroughIDs = Array(trackInfos.dropFirst().map(\.id))
            let defaultMapping = AudioTrackMapping.multiTrack(
                narrationTrackID: narrationID,
                passthroughTrackIDs: passthroughIDs
            )
            return .multiTrack(tracks: trackInfos, defaultMapping: defaultMapping)
        }
    }

    /// Validates an AudioTrackMapping against the inspected audio tracks.
    public func validate(mapping: AudioTrackMapping, against tracks: [AudioTrackInfo]) throws {
        let availableIDs = Set(tracks.map(\.id))

        guard availableIDs.contains(mapping.designatedNarrationTrackID) else {
            throw AudioTrackInspectorError.designatedTrackNotInAsset(mapping.designatedNarrationTrackID)
        }

        for passID in mapping.passthroughTrackIDs {
            guard availableIDs.contains(passID) else {
                throw AudioTrackInspectorError.passthroughTrackNotInAsset(passID)
            }
        }

        if mapping.passthroughTrackIDs.contains(mapping.designatedNarrationTrackID) {
            throw AudioTrackInspectorError.narrationInPassthroughList(mapping.designatedNarrationTrackID)
        }

        let uniquePassthrough = Set(mapping.passthroughTrackIDs)
        if uniquePassthrough.count != mapping.passthroughTrackIDs.count {
            throw AudioTrackInspectorError.duplicatePassthroughTrackIDs(mapping.passthroughTrackIDs)
        }

        if mapping.isSingleTrackAdvisory && (!mapping.passthroughTrackIDs.isEmpty || tracks.count > 1) {
            throw AudioTrackInspectorError.singleTrackAdvisoryViolation(
                "Single-track advisory mapping cannot contain passthrough tracks or be applied to multi-track assets."
            )
        }
    }

    private func fourCharCodeToString(_ code: FourCharCode) -> String {
        let n = UInt32(code)
        let b1 = UInt8((n >> 24) & 0xFF)
        let b2 = UInt8((n >> 16) & 0xFF)
        let b3 = UInt8((n >> 8) & 0xFF)
        let b4 = UInt8(n & 0xFF)
        let chars = [b1, b2, b3, b4].map { byte -> Character in
            if byte >= 32 && byte <= 126 {
                return Character(UnicodeScalar(byte))
            }
            return " "
        }
        let str = String(chars).trimmingCharacters(in: .whitespaces)
        return str.isEmpty ? "unknown" : str
    }
}
