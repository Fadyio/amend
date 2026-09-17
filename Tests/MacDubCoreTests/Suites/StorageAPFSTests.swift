import Testing
import Foundation
import CoreMedia
@testable import MacDubCore

@Suite("Storage APFS Tests")
final class StorageAPFSTests {
    private let tempDirectory: URL

    init() throws {
        let uniqueID = UUID().uuidString
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDubStorageTests_\(uniqueID)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    @Test("APFS cloning detected on APFS volume")
    func test_apfs_cloning_detected_on_apfs_volume() {
        let supportsCloning = APFSCloner.volumeSupportsCloning(at: tempDirectory)
        // On modern macOS systems running on Apple Silicon, APFS is the native filesystem
        #expect(supportsCloning, "Temporary directory volume must support APFS cloning.")
    }

    @Test("APFS copyItem creates clone source file")
    func test_apfs_copyItem_creates_clone_source_file() throws {
        // 1. Create a dummy media file
        let sourceURL = tempDirectory.appendingPathComponent("sample_screen_recording.mov")
        let dummyData = Data(repeating: 0x5A, count: 1024 * 1024) // 1 MB synthetic payload
        try dummyData.write(to: sourceURL)

        // 2. Prepare bundle directory
        let bundleURL = tempDirectory.appendingPathComponent("TestProject.voicefix", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // 3. Clone source into bundle
        let (clonedURL, relativePath) = try APFSCloner.cloneMedia(from: sourceURL, intoBundle: bundleURL)

        #expect(FileManager.default.fileExists(atPath: clonedURL.path))
        #expect(relativePath == "source.mov")

        let clonedData = try Data(contentsOf: clonedURL)
        #expect(clonedData.count == dummyData.count)
        #expect(clonedData == dummyData)
    }

    @Test("Bookmark fallback creation and resolution")
    func test_bookmark_fallback_creation_and_resolution() throws {
        // 1. Create external media file
        let externalMediaURL = tempDirectory.appendingPathComponent("external_recording.mp4")
        let payload = "Dummy video payload for bookmark testing".data(using: .utf8)!
        try payload.write(to: externalMediaURL)

        // 2. Create bookmark
        let bookmarkData = try BookmarkManager.createBookmark(for: externalMediaURL)
        #expect(!bookmarkData.isEmpty)

        // 3. Resolve bookmark
        let (resolvedURL, isStale) = try BookmarkManager.resolve(bookmarkData: bookmarkData)
        #expect(!isStale)
        #expect(resolvedURL.resolvingSymlinksInPath().path == externalMediaURL.resolvingSymlinksInPath().path)
        #expect(FileManager.default.fileExists(atPath: resolvedURL.path))
    }

    @Test("Project metadata serialization roundtrip")
    func test_project_metadata_serialization_roundtrip() throws {
        let duration = CMTime(value: 9000, timescale: 600, flags: .init(rawValue: 1), epoch: 0)
        let originalCues = [
            Cue(
                timeRange: CMTimeRange(
                    start: CMTime(value: 0, timescale: 600),
                    duration: CMTime(value: 3000, timescale: 600)
                ),
                text: "Hello and welcome to the demo.",
                originalText: "Hello and welcome to the demo.",
                editState: .original
            ),
            Cue(
                timeRange: CMTimeRange(
                    start: CMTime(value: 3000, timescale: 600),
                    duration: CMTime(value: 6000, timescale: 600)
                ),
                text: "Here we replace the narration.",
                originalText: "Original speech here.",
                audioWAVRelativePath: "audio/cues/cue_1.wav",
                editState: .synthesized,
                overflowDelta: CMTime(value: 120, timescale: 600)
            )
        ]

        let metadata = ProjectMetadata(
            name: "MacDub Project Alpha",
            sourceStorageMode: .cloned(relativePath: "source.mov"),
            designatedNarrationTrackID: 1,
            passthroughTrackIDs: [2, 3],
            isSingleTrackAdvisory: false,
            totalDuration: duration,
            roomToneRelativePath: "audio/room_tone.wav",
            cues: originalCues
        )

        let encoder = ProjectBundleSerializer.makeEncoder()
        let encodedData = try encoder.encode(metadata)

        let decoder = ProjectBundleSerializer.makeDecoder()
        let decoded = try decoder.decode(ProjectMetadata.self, from: encodedData)

        #expect(decoded.id == metadata.id)
        #expect(decoded.name == metadata.name)
        #expect(decoded.designatedNarrationTrackID == metadata.designatedNarrationTrackID)
        #expect(decoded.passthroughTrackIDs == metadata.passthroughTrackIDs)
        #expect(decoded.isSingleTrackAdvisory == metadata.isSingleTrackAdvisory)
        #expect(CMTimeCompare(decoded.totalDuration, metadata.totalDuration) == 0)
        #expect(decoded.roomToneRelativePath == metadata.roomToneRelativePath)
        #expect(decoded.sourceStorageMode == metadata.sourceStorageMode)
        #expect(decoded.sourceMode == "cloned")

        #expect(decoded.cues.count == originalCues.count)
        for (idx, cue) in decoded.cues.enumerated() {
            let original = originalCues[idx]
            #expect(cue.id == original.id)
            #expect(cue.text == original.text)
            #expect(cue.originalText == original.originalText)
            #expect(cue.editState == original.editState)
            #expect(cue.audioWAVRelativePath == original.audioWAVRelativePath)
            #expect(CMTimeCompare(cue.timeRange.start, original.timeRange.start) == 0)
            #expect(CMTimeCompare(cue.timeRange.duration, original.timeRange.duration) == 0)
            if let expectedDelta = original.overflowDelta, let decodedDelta = cue.overflowDelta {
                #expect(CMTimeCompare(expectedDelta, decodedDelta) == 0)
            } else {
                #expect(cue.overflowDelta == nil)
            }
        }
    }

    @Test("Cue CMTimeRange Codable rational precision")
    func test_cue_cmtimerange_codable_rational_precision() throws {
        // Test audio timescale (48,000 Hz) and video timescale (600)
        let audioStartTime = CMTime(value: 1_234_567, timescale: 48_000)
        let audioDuration = CMTime(value: 96_000, timescale: 48_000)
        let audioRange = CMTimeRange(start: audioStartTime, duration: audioDuration)

        let cue = Cue(
            timeRange: audioRange,
            text: "High precision audio clock test."
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(cue)

        let decoder = JSONDecoder()
        let decodedCue = try decoder.decode(Cue.self, from: data)

        // Strict rational equality assertions: value and timescale must match exactly
        #expect(decodedCue.timeRange.start.value == 1_234_567)
        #expect(decodedCue.timeRange.start.timescale == 48_000)
        #expect(decodedCue.timeRange.duration.value == 96_000)
        #expect(decodedCue.timeRange.duration.timescale == 48_000)
        #expect(CMTimeCompare(decodedCue.timeRange.start, audioStartTime) == 0)
        #expect(CMTimeCompare(decodedCue.timeRange.duration, audioDuration) == 0)
    }

    @Test("Project bundle directory scaffolding")
    func test_project_bundle_directory_scaffolding() throws {
        let bundleURL = tempDirectory.appendingPathComponent("ScaffoldTest.voicefix")
        let metadata = ProjectMetadata(
            name: "ScaffoldTest",
            sourceStorageMode: .cloned(relativePath: "source.mp4"),
            designatedNarrationTrackID: 1,
            totalDuration: CMTime(value: 3000, timescale: 600)
        )

        let bundle = try ProjectBundle.create(at: bundleURL, metadata: metadata)
        let fm = FileManager.default

        #expect(fm.fileExists(atPath: bundle.projectJSONURL.path))
        #expect(fm.fileExists(atPath: bundle.cuesAudioDirectoryURL.path))
        #expect(fm.fileExists(atPath: bundle.waveformsDirectoryURL.path))
        #expect(fm.fileExists(atPath: bundle.thumbnailsDirectoryURL.path))

        let loadedBundle = try ProjectBundleSerializer.load(from: bundle.rootURL)
        #expect(loadedBundle.metadata.name == "ScaffoldTest")
    }

    @Test("Project bundle serializer create and resolve")
    func test_project_bundle_serializer_create_and_resolve() throws {
        let sourceURL = tempDirectory.appendingPathComponent("original.mp4")
        let content = "Sample video content".data(using: .utf8)!
        try content.write(to: sourceURL)

        let destURL = tempDirectory.appendingPathComponent("MyProject")
        let bundle = try ProjectBundleSerializer.createBundle(
            at: destURL,
            sourceMediaURL: sourceURL,
            name: "MyProject",
            designatedNarrationTrackID: 1,
            passthroughTrackIDs: [2],
            isSingleTrackAdvisory: false,
            totalDuration: CMTime(value: 600, timescale: 30)
        )

        #expect(bundle.rootURL.pathExtension == ProjectBundle.packageExtension)
        #expect(FileManager.default.fileExists(atPath: bundle.projectJSONURL.path))

        let resolvedURL = try ProjectBundleSerializer.resolveSourceMediaURL(for: bundle)
        #expect(FileManager.default.fileExists(atPath: resolvedURL.path))
    }
}
