import Testing
import Foundation
import CoreMedia
import UniformTypeIdentifiers
@testable import AmendCore
@testable import AmendApp

@Suite("Amend Project Format & System Association Tests")
struct AmendProjectFormatTests {

    @Test(".amend package creation creates expected directory layout and project.json")
    func test_amend_package_creation() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmendFormatTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("DemoRecording.amend")
        let metadata = ProjectMetadata(
            name: "DemoRecording",
            sourceStorageMode: .cloned(relativePath: "source.mov"),
            designatedNarrationTrackID: 1,
            passthroughTrackIDs: [2],
            isSingleTrackAdvisory: false,
            totalDuration: CMTime(seconds: 10.0, preferredTimescale: 600),
            cues: []
        )

        let bundle = try ProjectBundle.create(at: bundleURL, metadata: metadata)
        #expect(bundle.rootURL.pathExtension == "amend")
        #expect(FileManager.default.fileExists(atPath: bundle.projectJSONURL.path))
        #expect(FileManager.default.fileExists(atPath: bundle.cuesAudioDirectoryURL.path))
        #expect(FileManager.default.fileExists(atPath: bundle.waveformsDirectoryURL.path))
        #expect(FileManager.default.fileExists(atPath: bundle.thumbnailsDirectoryURL.path))
        #expect(ProjectBundle.packageExtension == "amend")
    }

    @Test(".amend project save and load preserves all project metadata and cues")
    func test_amend_save_load_roundtrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmendSaveLoadTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("SaveLoadProject.amend")
        let cue1 = Cue(
            id: UUID(),
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 3.0, preferredTimescale: 600)),
            text: "First cue line in Amend.",
            originalText: "First cue line in Amend.",
            editState: .edited
        )
        let metadata = ProjectMetadata(
            name: "SaveLoadProject",
            sourceStorageMode: .cloned(relativePath: "source.mp4"),
            designatedNarrationTrackID: 1,
            passthroughTrackIDs: [],
            isSingleTrackAdvisory: true,
            totalDuration: CMTime(seconds: 15.0, preferredTimescale: 600),
            cues: [cue1]
        )

        let initialBundle = try ProjectBundle.create(at: bundleURL, metadata: metadata)
        let loadedBundle = try ProjectBundleSerializer.load(from: initialBundle.rootURL)

        #expect(loadedBundle.metadata.name == "SaveLoadProject")
        #expect(loadedBundle.cues.count == 1)
        #expect(loadedBundle.cues.first?.text == "First cue line in Amend.")
        #expect(loadedBundle.metadata.designatedNarrationTrackID == 1)
        #expect(loadedBundle.metadata.isSingleTrackAdvisory == true)
        #expect(loadedBundle.rootURL.pathExtension == "amend")
    }

    @Test("Packaging/Info.plist registers .amend extension, Amend Project display name, and com.fady.amend.project UTI")
    func test_info_plist_file_association() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Suites
            .deletingLastPathComponent() // AmendCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Repository root

        let plistURL = projectRoot.appendingPathComponent("Packaging/Info.plist")
        #expect(FileManager.default.fileExists(atPath: plistURL.path))

        let data = try Data(contentsOf: plistURL)
        let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dict = propertyList as? [String: Any] else {
            Issue.record("Packaging/Info.plist could not be parsed as dictionary")
            return
        }

        // CFBundle identity
        #expect(dict["CFBundleName"] as? String == "Amend")
        #expect(dict["CFBundleDisplayName"] as? String == "Amend")
        #expect(dict["CFBundleExecutable"] as? String == "Amend")
        #expect(dict["CFBundleIdentifier"] as? String == "com.fady.amend")

        // CFBundleDocumentTypes
        guard let docTypes = dict["CFBundleDocumentTypes"] as? [[String: Any]], !docTypes.isEmpty else {
            Issue.record("Missing CFBundleDocumentTypes in Info.plist")
            return
        }

        let amendDocType = docTypes.first { ($0["LSItemContentTypes"] as? [String])?.contains("com.fady.amend.project") == true }
        #expect(amendDocType != nil)
        #expect(amendDocType?["CFBundleTypeName"] as? String == "Amend Project")
        #expect(amendDocType?["LSHandlerRank"] as? String == "Owner")
        #expect(amendDocType?["LSTypeIsPackage"] as? Bool == true)

        // UTExportedTypeDeclarations
        guard let utDeclarations = dict["UTExportedTypeDeclarations"] as? [[String: Any]], !utDeclarations.isEmpty else {
            Issue.record("Missing UTExportedTypeDeclarations in Info.plist")
            return
        }

        let amendUTI = utDeclarations.first { $0["UTTypeIdentifier"] as? String == "com.fady.amend.project" }
        #expect(amendUTI != nil)
        #expect(amendUTI?["UTTypeDescription"] as? String == "Amend Project")
        if let tagSpec = amendUTI?["UTTypeTagSpecification"] as? [String: Any],
           let extensions = tagSpec["public.filename-extension"] as? [String] {
            #expect(extensions.contains("amend"))
        } else {
            Issue.record("UTTypeTagSpecification does not contain public.filename-extension")
        }
    }

    @Test("Open URL routing recognizes .amend project bundles")
    @MainActor
    func test_open_url_routing_for_amend_bundles() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmendRoutingTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("MyRecordedDemo.amend")
        let metadata = ProjectMetadata(
            name: "MyRecordedDemo",
            sourceStorageMode: .cloned(relativePath: "source.mov"),
            designatedNarrationTrackID: 1,
            passthroughTrackIDs: [],
            isSingleTrackAdvisory: false,
            totalDuration: CMTime(seconds: 5.0, preferredTimescale: 600),
            cues: []
        )
        _ = try ProjectBundle.create(at: bundleURL, metadata: metadata)

        // Simulate open URL routing handler as configured in AmendMain
        let appVM = AppViewModel()
        var openedProjectURL: URL?
        let openHandler: (URL) -> Void = { url in
            if url.pathExtension.lowercased() == "amend" {
                try? appVM.loadProject(from: url)
                openedProjectURL = url
            }
        }

        openHandler(bundleURL)
        #expect(openedProjectURL == bundleURL)
        #expect(appVM.projectBundleURL == bundleURL)
        #expect(appVM.statusMessage.contains("Project loaded"))
    }
}
