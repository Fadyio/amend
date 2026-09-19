import Foundation

public enum CueEditState: String, Codable, Equatable, Sendable, CaseIterable {
    case original
    case edited
    case synthesized
    case overflowGated
    case forceFitted
}
