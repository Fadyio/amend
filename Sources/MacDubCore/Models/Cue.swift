import Foundation
import CoreMedia

public struct Cue: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timeRange: CMTimeRange // Immutable slot boundaries
    public var text: String
    public var originalText: String
    public var audioWAVRelativePath: String? // Approved active replacement audio
    public var candidateAudioWAVRelativePath: String? // Unapproved candidate audio (e.g. overflowGated)
    public var editState: CueEditState
    public var overflowDelta: CMTime? // Set when exceeding duration > 8%

    public init(
        id: UUID = UUID(),
        timeRange: CMTimeRange,
        text: String,
        originalText: String? = nil,
        audioWAVRelativePath: String? = nil,
        candidateAudioWAVRelativePath: String? = nil,
        editState: CueEditState = .original,
        overflowDelta: CMTime? = nil
    ) {
        self.id = id
        self.timeRange = timeRange
        self.text = text
        self.originalText = originalText ?? text
        self.audioWAVRelativePath = audioWAVRelativePath
        self.candidateAudioWAVRelativePath = candidateAudioWAVRelativePath
        self.editState = editState
        self.overflowDelta = overflowDelta
    }

    public var start: CMTime { timeRange.start }
    public var duration: CMTime { timeRange.duration }
    public var end: CMTime { timeRange.end }

    enum CodingKeys: String, CodingKey {
        case id
        case timeRange
        case text
        case originalText
        case audioWAVRelativePath
        case candidateAudioWAVRelativePath
        case editState
        case overflowDelta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.timeRange = try container.decode(CMTimeRange.self, forKey: .timeRange)
        self.text = try container.decode(String.self, forKey: .text)
        self.originalText = try container.decodeIfPresent(String.self, forKey: .originalText) ?? self.text
        self.audioWAVRelativePath = try container.decodeIfPresent(String.self, forKey: .audioWAVRelativePath)
        self.candidateAudioWAVRelativePath = try container.decodeIfPresent(String.self, forKey: .candidateAudioWAVRelativePath)
        self.editState = try container.decodeIfPresent(CueEditState.self, forKey: .editState) ?? .original
        self.overflowDelta = try container.decodeIfPresent(CMTime.self, forKey: .overflowDelta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timeRange, forKey: .timeRange)
        try container.encode(text, forKey: .text)
        try container.encode(originalText, forKey: .originalText)
        try container.encodeIfPresent(audioWAVRelativePath, forKey: .audioWAVRelativePath)
        try container.encodeIfPresent(candidateAudioWAVRelativePath, forKey: .candidateAudioWAVRelativePath)
        try container.encode(editState, forKey: .editState)
        try container.encodeIfPresent(overflowDelta, forKey: .overflowDelta)
    }
}

extension Cue {
    /// Creates a functional copy with updated narration text, preserving immutable timeRange and originalText.
    public func withUpdatedText(_ newText: String) -> Cue {
        Cue(
            id: self.id,
            timeRange: self.timeRange, // Strictly immutable
            text: newText,
            originalText: self.originalText,
            audioWAVRelativePath: self.audioWAVRelativePath,
            candidateAudioWAVRelativePath: nil,
            editState: .edited,
            overflowDelta: nil
        )
    }

    /// Creates a functional copy with updated approved audio replacement, clearing any pending candidate.
    public func withUpdatedAudio(
        audioWAVRelativePath: String?,
        editState: CueEditState,
        overflowDelta: CMTime? = nil
    ) -> Cue {
        Cue(
            id: self.id,
            timeRange: self.timeRange, // Strictly immutable
            text: self.text,
            originalText: self.originalText,
            audioWAVRelativePath: audioWAVRelativePath,
            candidateAudioWAVRelativePath: nil,
            editState: editState,
            overflowDelta: overflowDelta
        )
    }

    /// Creates a functional copy with pending overflowing candidate audio, preserving previous approved audio.
    public func withCandidateAudio(
        candidateAudioWAVRelativePath: String?,
        overflowDelta: CMTime?
    ) -> Cue {
        Cue(
            id: self.id,
            timeRange: self.timeRange,
            text: self.text,
            originalText: self.originalText,
            audioWAVRelativePath: self.audioWAVRelativePath, // Keep previous active replacement untouched
            candidateAudioWAVRelativePath: candidateAudioWAVRelativePath,
            editState: .overflowGated,
            overflowDelta: overflowDelta
        )
    }

    /// Discards candidate audio and restores previous edit state.
    public func withDiscardedCandidate() -> Cue {
        let restoredState: CueEditState
        if audioWAVRelativePath != nil {
            restoredState = .synthesized
        } else if text != originalText {
            restoredState = .edited
        } else {
            restoredState = .original
        }
        return Cue(
            id: self.id,
            timeRange: self.timeRange,
            text: self.text,
            originalText: self.originalText,
            audioWAVRelativePath: self.audioWAVRelativePath,
            candidateAudioWAVRelativePath: nil,
            editState: restoredState,
            overflowDelta: nil
        )
    }

    /// Checks whether a given continuous timestamp falls within this cue's slot boundaries [start, end).
    public func contains(time: CMTime) -> Bool {
        CMTimeCompare(time, timeRange.start) >= 0 && CMTimeCompare(time, timeRange.end) < 0
    }
}
