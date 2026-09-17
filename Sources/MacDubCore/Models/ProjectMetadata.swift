import Foundation
import CoreMedia

public struct ProjectMetadata: Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var sourceStorageMode: SourceStorageMode
    public var designatedNarrationTrackID: Int
    public var passthroughTrackIDs: [Int]
    public var isSingleTrackAdvisory: Bool
    public var totalDuration: CMTime
    public var roomToneRelativePath: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var cues: [Cue]
    public var referenceVoice: ReferenceVoice?
    public var activeProviderType: SynthesisProviderType?
    public var nominalFrameRate: Double?
    public var geminiModel: String?
    public var resembleVoiceUUID: String?
    public var elevenLabsVoiceID: String?

    // Convenience accessor matching spec miner test criteria
    public var sourceMode: SourceStorageMode {
        get { sourceStorageMode }
        set { sourceStorageMode = newValue }
    }

    public var audioTrackMapping: AudioTrackMapping {
        get {
            AudioTrackMapping(
                designatedNarrationTrackID: designatedNarrationTrackID,
                passthroughTrackIDs: passthroughTrackIDs,
                isSingleTrackAdvisory: isSingleTrackAdvisory
            )
        }
        set {
            designatedNarrationTrackID = newValue.designatedNarrationTrackID
            passthroughTrackIDs = newValue.passthroughTrackIDs
            isSingleTrackAdvisory = newValue.isSingleTrackAdvisory
        }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        sourceStorageMode: SourceStorageMode,
        designatedNarrationTrackID: Int,
        passthroughTrackIDs: [Int] = [],
        isSingleTrackAdvisory: Bool = false,
        totalDuration: CMTime,
        roomToneRelativePath: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        cues: [Cue] = [],
        referenceVoice: ReferenceVoice? = nil,
        activeProviderType: SynthesisProviderType? = nil,
        nominalFrameRate: Double? = nil,
        geminiModel: String? = nil,
        resembleVoiceUUID: String? = nil,
        elevenLabsVoiceID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.sourceStorageMode = sourceStorageMode
        self.designatedNarrationTrackID = designatedNarrationTrackID
        self.passthroughTrackIDs = passthroughTrackIDs
        self.isSingleTrackAdvisory = isSingleTrackAdvisory
        self.totalDuration = totalDuration
        self.roomToneRelativePath = roomToneRelativePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.cues = cues
        self.referenceVoice = referenceVoice
        self.activeProviderType = activeProviderType
        self.nominalFrameRate = nominalFrameRate
        self.geminiModel = geminiModel
        self.resembleVoiceUUID = resembleVoiceUUID
        self.elevenLabsVoiceID = elevenLabsVoiceID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case sourceStorageMode
        case sourceMode
        case designatedNarrationTrackID
        case passthroughTrackIDs
        case isSingleTrackAdvisory
        case totalDuration
        case roomToneRelativePath
        case createdAt
        case updatedAt
        case cues
        case referenceVoice
        case activeProviderType
        case nominalFrameRate
        case geminiModel
        case resembleVoiceUUID
        case elevenLabsVoiceID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)

        if let mode = try container.decodeIfPresent(SourceStorageMode.self, forKey: .sourceStorageMode) {
            self.sourceStorageMode = mode
        } else if let mode = try container.decodeIfPresent(SourceStorageMode.self, forKey: .sourceMode) {
            self.sourceStorageMode = mode
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.sourceStorageMode,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "No source storage mode found")
            )
        }

        self.designatedNarrationTrackID = try container.decode(Int.self, forKey: .designatedNarrationTrackID)
        self.passthroughTrackIDs = try container.decodeIfPresent([Int].self, forKey: .passthroughTrackIDs) ?? []
        self.isSingleTrackAdvisory = try container.decodeIfPresent(Bool.self, forKey: .isSingleTrackAdvisory) ?? false
        self.totalDuration = try container.decode(CMTime.self, forKey: .totalDuration)
        self.roomToneRelativePath = try container.decodeIfPresent(String.self, forKey: .roomToneRelativePath)
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        self.cues = try container.decodeIfPresent([Cue].self, forKey: .cues) ?? []
        self.referenceVoice = try container.decodeIfPresent(ReferenceVoice.self, forKey: .referenceVoice)
        self.activeProviderType = try container.decodeIfPresent(SynthesisProviderType.self, forKey: .activeProviderType)
        self.nominalFrameRate = try container.decodeIfPresent(Double.self, forKey: .nominalFrameRate)
        self.geminiModel = try container.decodeIfPresent(String.self, forKey: .geminiModel)
        self.resembleVoiceUUID = try container.decodeIfPresent(String.self, forKey: .resembleVoiceUUID)
        self.elevenLabsVoiceID = try container.decodeIfPresent(String.self, forKey: .elevenLabsVoiceID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(sourceStorageMode, forKey: .sourceStorageMode)
        try container.encode(sourceStorageMode, forKey: .sourceMode)
        try container.encode(designatedNarrationTrackID, forKey: .designatedNarrationTrackID)
        try container.encode(passthroughTrackIDs, forKey: .passthroughTrackIDs)
        try container.encode(isSingleTrackAdvisory, forKey: .isSingleTrackAdvisory)
        try container.encode(totalDuration, forKey: .totalDuration)
        try container.encodeIfPresent(roomToneRelativePath, forKey: .roomToneRelativePath)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(cues, forKey: .cues)
        try container.encodeIfPresent(referenceVoice, forKey: .referenceVoice)
        try container.encodeIfPresent(activeProviderType, forKey: .activeProviderType)
        try container.encodeIfPresent(nominalFrameRate, forKey: .nominalFrameRate)
        try container.encodeIfPresent(geminiModel, forKey: .geminiModel)
        try container.encodeIfPresent(resembleVoiceUUID, forKey: .resembleVoiceUUID)
        try container.encodeIfPresent(elevenLabsVoiceID, forKey: .elevenLabsVoiceID)
    }
}
