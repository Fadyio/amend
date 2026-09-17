import Foundation

public enum VoiceCloningStatus: String, Codable, Equatable, Sendable {
    case unconfigured = "Unconfigured"
    case ready = "Ready"
    case failed = "Failed"
}

public struct ReferenceVoice: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var audioRelativePath: String
    public var pocketTTSStatus: VoiceCloningStatus
    public var elevenLabsVoiceID: String?
    public var resembleVoiceUUID: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        audioRelativePath: String,
        pocketTTSStatus: VoiceCloningStatus = .ready,
        elevenLabsVoiceID: String? = nil,
        resembleVoiceUUID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.audioRelativePath = audioRelativePath
        self.pocketTTSStatus = pocketTTSStatus
        self.elevenLabsVoiceID = elevenLabsVoiceID
        self.resembleVoiceUUID = resembleVoiceUUID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
