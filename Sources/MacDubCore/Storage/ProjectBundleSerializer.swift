import Foundation
import CoreMedia

public enum ProjectBundleSerializerError: Error, LocalizedError {
    case invalidBundleDirectory(URL)
    case missingProjectJSON(URL)
    case unresolvableMedia(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidBundleDirectory(let url):
            return "Path is not a valid project directory: \(url.path)"
        case .missingProjectJSON(let url):
            return "project.json not found in bundle: \(url.path)"
        case .unresolvableMedia(let err):
            return "Failed to resolve project source media: \(err.localizedDescription)"
        }
    }
}

public struct ProjectBundleSerializer: Sendable {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func createBundle(
        at destinationURL: URL,
        sourceMediaURL: URL,
        name: String,
        designatedNarrationTrackID: Int,
        passthroughTrackIDs: [Int] = [],
        isSingleTrackAdvisory: Bool = false,
        totalDuration: CMTime
    ) throws -> ProjectBundle {
        var bundleURL = destinationURL
        if bundleURL.pathExtension != ProjectBundle.packageExtension {
            bundleURL = bundleURL.appendingPathExtension(ProjectBundle.packageExtension)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: bundleURL.appendingPathComponent("audio/cues"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bundleURL.appendingPathComponent("waveforms"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bundleURL.appendingPathComponent("thumbnails"), withIntermediateDirectories: true)

        let sourceMode: SourceStorageMode
        if APFSCloner.canClone(from: sourceMediaURL, to: bundleURL) {
            let ext = sourceMediaURL.pathExtension.isEmpty ? "mp4" : sourceMediaURL.pathExtension
            let clonedRelative = "source.\(ext)"
            let targetClonedURL = bundleURL.appendingPathComponent(clonedRelative)
            do {
                try APFSCloner.clone(from: sourceMediaURL, to: targetClonedURL)
                sourceMode = .cloned(relativePath: clonedRelative)
            } catch {
                let bookmarkData = try BookmarkManager.createBookmark(for: sourceMediaURL)
                sourceMode = .externalBookmark(bookmarkData: bookmarkData, originalPath: sourceMediaURL.path)
            }
        } else {
            let bookmarkData = try BookmarkManager.createBookmark(for: sourceMediaURL)
            sourceMode = .externalBookmark(bookmarkData: bookmarkData, originalPath: sourceMediaURL.path)
        }

        let metadata = ProjectMetadata(
            name: name,
            sourceStorageMode: sourceMode,
            designatedNarrationTrackID: designatedNarrationTrackID,
            passthroughTrackIDs: passthroughTrackIDs,
            isSingleTrackAdvisory: isSingleTrackAdvisory,
            totalDuration: totalDuration,
            cues: []
        )

        let bundle = ProjectBundle(rootURL: bundleURL, metadata: metadata)
        try save(bundle: bundle)
        return bundle
    }

    public static func load(from bundleURL: URL) throws -> ProjectBundle {
        let projectJSON = bundleURL.appendingPathComponent(ProjectBundle.projectFileName)
        guard FileManager.default.fileExists(atPath: projectJSON.path) else {
            throw ProjectBundleSerializerError.missingProjectJSON(bundleURL)
        }

        let data = try Data(contentsOf: projectJSON)
        let metadata = try makeDecoder().decode(ProjectMetadata.self, from: data)

        // Ensure cache directories exist
        let fm = FileManager.default
        try? fm.createDirectory(at: bundleURL.appendingPathComponent("audio/cues"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: bundleURL.appendingPathComponent("waveforms"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: bundleURL.appendingPathComponent("thumbnails"), withIntermediateDirectories: true)

        return ProjectBundle(rootURL: bundleURL, metadata: metadata)
    }

    public static func save(bundle: ProjectBundle) throws {
        var updatedMetadata = bundle.metadata
        updatedMetadata.updatedAt = Date()

        let data = try makeEncoder().encode(updatedMetadata)
        try data.write(to: bundle.projectJSONURL, options: .atomic)
    }

    public static func resolveSourceMediaURL(for bundle: ProjectBundle) throws -> URL {
        switch bundle.metadata.sourceStorageMode {
        case .cloned(let relativePath):
            return bundle.rootURL.appendingPathComponent(relativePath)
        case .externalBookmark(let bookmarkData, _):
            let (resolvedURL, isStale) = try BookmarkManager.resolveBookmark(data: bookmarkData)
            if isStale {
                if let refreshed = try? BookmarkManager.createBookmark(for: resolvedURL) {
                    var mutableBundle = bundle
                    mutableBundle.metadata.sourceStorageMode = .externalBookmark(
                        bookmarkData: refreshed,
                        originalPath: resolvedURL.path
                    )
                    try? save(bundle: mutableBundle)
                }
            }
            return resolvedURL
        }
    }
}
