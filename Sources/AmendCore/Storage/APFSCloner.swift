import Foundation

public enum APFSCloningError: Error, LocalizedError {
    case unsupportedVolume
    case crossVolumeCloningUnsupported
    case cloningFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVolume:
            return "The destination volume does not support APFS copy-on-write cloning."
        case .crossVolumeCloningUnsupported:
            return "Source and destination are on different filesystem volumes; cloning is impossible."
        case .cloningFailed(let err):
            return "APFS cloning failed: \(err.localizedDescription)"
        }
    }
}

public struct APFSCloner: Sendable {
    private static func existingURL(for url: URL) -> URL {
        var check = url.resolvingSymlinksInPath()
        while !FileManager.default.fileExists(atPath: check.path) && check.path != "/" {
            check = check.deletingLastPathComponent()
        }
        return check
    }

    public static func volumeSupportsCloning(at url: URL) -> Bool {
        let check = existingURL(for: url)
        guard let values = try? check.resourceValues(forKeys: [.volumeSupportsFileCloningKey]),
              let supported = values.volumeSupportsFileCloning else {
            return false
        }
        return supported
    }

    public static func areOnSameVolume(_ url1: URL, _ url2: URL) -> Bool {
        let check1 = existingURL(for: url1)
        let check2 = existingURL(for: url2)
        guard let v1 = try? check1.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let v2 = try? check2.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else {
            return false
        }
        return (v1 as AnyObject).isEqual(v2)
    }

    public static func canClone(from source: URL, to destination: URL) -> Bool {
        volumeSupportsCloning(at: destination) && areOnSameVolume(source, destination)
    }

    public static func clone(from source: URL, to destination: URL) throws {
        guard volumeSupportsCloning(at: destination) else {
            throw APFSCloningError.unsupportedVolume
        }
        guard areOnSameVolume(source, destination) else {
            throw APFSCloningError.crossVolumeCloningUnsupported
        }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw APFSCloningError.cloningFailed(error)
        }
    }

    @discardableResult
    public static func cloneMedia(from sourceURL: URL, intoBundle bundleURL: URL) throws -> (clonedURL: URL, relativePath: String) {
        let ext = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
        let relativePath = "source.\(ext)"
        let targetURL = bundleURL.appendingPathComponent(relativePath)
        try clone(from: sourceURL, to: targetURL)
        return (targetURL, relativePath)
    }
}
