import Foundation

public struct ProjectBundle: Equatable, Sendable {
    public static let packageExtension = "amend"
    public static let projectFileName = "project.json"

    public let rootURL: URL
    public var metadata: ProjectMetadata

    public var cues: [Cue] {
        get { metadata.cues }
        set { metadata.cues = newValue }
    }

    public var projectJSONURL: URL {
        rootURL.appendingPathComponent(Self.projectFileName)
    }

    public var audioDirectoryURL: URL {
        rootURL.appendingPathComponent("audio")
    }

    public var cuesAudioDirectoryURL: URL {
        audioDirectoryURL.appendingPathComponent("cues")
    }

    public var waveformsDirectoryURL: URL {
        rootURL.appendingPathComponent("waveforms")
    }

    public var thumbnailsDirectoryURL: URL {
        rootURL.appendingPathComponent("thumbnails")
    }

    public init(rootURL: URL, metadata: ProjectMetadata) {
        self.rootURL = rootURL
        self.metadata = metadata
    }

    public static func create(at bundleURL: URL, metadata: ProjectMetadata) throws -> ProjectBundle {
        var finalURL = bundleURL
        if finalURL.pathExtension != Self.packageExtension {
            finalURL = finalURL.appendingPathExtension(Self.packageExtension)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: finalURL.appendingPathComponent("audio/cues"), withIntermediateDirectories: true)
        try fm.createDirectory(at: finalURL.appendingPathComponent("waveforms"), withIntermediateDirectories: true)
        try fm.createDirectory(at: finalURL.appendingPathComponent("thumbnails"), withIntermediateDirectories: true)

        let bundle = ProjectBundle(rootURL: finalURL, metadata: metadata)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: bundle.projectJSONURL, options: .atomic)

        return bundle
    }
}
