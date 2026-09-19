import Foundation

public struct AudioTrackMapping: Codable, Equatable, Sendable {
    public var designatedNarrationTrackID: Int
    public var passthroughTrackIDs: [Int]
    public var isSingleTrackAdvisory: Bool

    public init(
        designatedNarrationTrackID: Int,
        passthroughTrackIDs: [Int] = [],
        isSingleTrackAdvisory: Bool = false
    ) {
        self.designatedNarrationTrackID = designatedNarrationTrackID
        self.passthroughTrackIDs = passthroughTrackIDs
        self.isSingleTrackAdvisory = isSingleTrackAdvisory
    }

    public static func singleTrack(trackID: Int) -> AudioTrackMapping {
        AudioTrackMapping(
            designatedNarrationTrackID: trackID,
            passthroughTrackIDs: [],
            isSingleTrackAdvisory: true
        )
    }

    public static func multiTrack(narrationTrackID: Int, passthroughTrackIDs: [Int]) -> AudioTrackMapping {
        AudioTrackMapping(
            designatedNarrationTrackID: narrationTrackID,
            passthroughTrackIDs: passthroughTrackIDs,
            isSingleTrackAdvisory: false
        )
    }

    public var allTrackIDs: [Int] {
        [designatedNarrationTrackID] + passthroughTrackIDs
    }

    public var isValid: Bool {
        !passthroughTrackIDs.contains(designatedNarrationTrackID) &&
        (!isSingleTrackAdvisory || passthroughTrackIDs.isEmpty)
    }
}
