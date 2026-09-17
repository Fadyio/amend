import Foundation

public enum BookmarkError: Error, LocalizedError {
    case creationFailed(Error)
    case resolutionFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .creationFailed(let err):
            return "Failed to create security-scoped bookmark: \(err.localizedDescription)"
        case .resolutionFailed(let err):
            return "Failed to resolve security-scoped bookmark: \(err.localizedDescription)"
        }
    }
}

public struct BookmarkManager: Sendable {
    public static func createBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            // Fallback for non-sandboxed environments (e.g. CLI tools / unit tests)
            do {
                return try url.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } catch let fallbackErr {
                throw BookmarkError.creationFailed(fallbackErr)
            }
        }
    }

    public static func resolveBookmark(data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
        } catch {
            do {
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                return (url, isStale)
            } catch let fallbackErr {
                throw BookmarkError.resolutionFailed(fallbackErr)
            }
        }
    }

    public static func resolve(bookmarkData: Data) throws -> (url: URL, isStale: Bool) {
        try resolveBookmark(data: bookmarkData)
    }

    public static func withSecurityScopedAccess<T>(to url: URL, block: (URL) throws -> T) throws -> T {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try block(url)
    }
}
