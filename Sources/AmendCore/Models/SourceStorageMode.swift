import Foundation

public enum SourceStorageMode: Codable, Equatable, Sendable {
    case cloned(relativePath: String)
    case externalBookmark(bookmarkData: Data, originalPath: String)

    public var modeName: String {
        switch self {
        case .cloned:
            return "cloned"
        case .externalBookmark:
            return "externalBookmark"
        }
    }
}

extension SourceStorageMode: CustomStringConvertible {
    public var description: String {
        modeName
    }
}

public func == (lhs: SourceStorageMode, rhs: String) -> Bool {
    lhs.modeName == rhs
}

public func == (lhs: String, rhs: SourceStorageMode) -> Bool {
    rhs == lhs
}

public func != (lhs: SourceStorageMode, rhs: String) -> Bool {
    lhs.modeName != rhs
}

public func != (lhs: String, rhs: SourceStorageMode) -> Bool {
    rhs != lhs
}
