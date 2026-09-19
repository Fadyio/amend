import Foundation
import CoreMedia

/// Represents metadata and characteristics of an audio track inspected from source media.
public struct AudioTrackInfo: Identifiable, Codable, Equatable, Sendable {
    public let id: Int
    public let format: String
    public let channelCount: Int
    public let sampleRate: Double
    public let bitDepth: Int?
    public let duration: CMTime
    public let timeRange: CMTimeRange
    public let languageCode: String?
    public let title: String?
    public let estimatedDataRate: Float

    public init(
        id: Int,
        format: String,
        channelCount: Int,
        sampleRate: Double,
        bitDepth: Int? = nil,
        duration: CMTime,
        timeRange: CMTimeRange,
        languageCode: String? = nil,
        title: String? = nil,
        estimatedDataRate: Float = 0.0
    ) {
        self.id = id
        self.format = format
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.duration = duration
        self.timeRange = timeRange
        self.languageCode = languageCode
        self.title = title
        self.estimatedDataRate = estimatedDataRate
    }

    public var displayName: String {
        title ?? "Audio Track \(id)"
    }

    public var formatName: String {
        format.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}
