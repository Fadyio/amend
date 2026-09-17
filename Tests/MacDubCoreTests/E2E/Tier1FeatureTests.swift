import Testing
import Foundation
import AVFoundation
import CoreMedia
@testable import MacDubCore

@Suite("Tier 1: Feature Coverage E2E Tests")
final class Tier1FeatureTests {
    private let tempDirectory: URL

    init() throws {
        let uniqueID = UUID().uuidString
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDubTier1Tests_\(uniqueID)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - Feature 47: Deterministic Synthetic Fixtures (ADR 0007)

    @Test("Feature 47: Fixture 1 Single-Track media generation and track verification")
    func test_feature47_fixture1_single_track_generation() async throws {
        let fileURL = tempDirectory.appendingPathComponent("fixture1_test.mov")
        let asset = try await Fixture1SingleTrack.generate(at: fileURL)

        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(asset.fileURL == fileURL)

        let avAsset = AVURLAsset(url: fileURL)
        let duration = try await avAsset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        #expect(abs(durationSeconds - 10.0) < 0.05, "Fixture 1 duration should be ~10.0s, got \(durationSeconds)")

        let videoTracks = try await avAsset.loadTracks(withMediaType: .video)
        #expect(videoTracks.count == 1, "Fixture 1 must contain exactly 1 video track")
        if let videoTrack = videoTracks.first {
            let size = try await videoTrack.load(.naturalSize)
            #expect(size.width == 640.0)
            #expect(size.height == 360.0)
            let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
            #expect(abs(nominalFrameRate - 30.0) < 0.1)
        }

        let audioTracks = try await avAsset.loadTracks(withMediaType: .audio)
        #expect(audioTracks.count == 1, "Fixture 1 must contain exactly 1 audio track")

        #expect(asset.expectedCues.count == 3)
        #expect(asset.roomToneRange != nil)
    }

    @Test("Feature 47: Fixture 2 Multi-Track media generation and independent audio tracks")
    func test_feature47_fixture2_multi_track_generation() async throws {
        let fileURL = tempDirectory.appendingPathComponent("fixture2_test.mov")
        let asset = try await Fixture2MultiTrack.generate(at: fileURL)

        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        let avAsset = AVURLAsset(url: fileURL)
        let videoTracks = try await avAsset.loadTracks(withMediaType: .video)
        #expect(videoTracks.count == 1)

        let audioTracks = try await avAsset.loadTracks(withMediaType: .audio)
        #expect(audioTracks.count == 2, "Fixture 2 must contain exactly 2 audio tracks (Narration + Passthrough)")

        let trackIDs = audioTracks.map { $0.trackID }
        #expect(trackIDs[0] != trackIDs[1], "Audio track IDs must be distinct")
        #expect(asset.audioTrackIDs.count == 2)
    }

    @Test("Feature 47: Fixture 3 Duration Fitting media and PCM replacement buffer synthesis")
    func test_feature47_fixture3_duration_fitting_buffers() async throws {
        let fileURL = tempDirectory.appendingPathComponent("fixture3_test.mov")
        let asset = try await Fixture3DurationFitting.generateBaseMedia(at: fileURL)

        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(asset.expectedCues.count == 1)
        #expect(CMTimeCompare(Fixture3DurationFitting.targetSlotDuration, CMTime(value: 20, timescale: 10)) == 0)

        // Generate and verify all 4 duration fitting scenarios
        let scenarios: [DurationFittingScenario] = [.shorter, .minorOverflow, .boundaryOverflow, .majorOverflow]
        for scenario in scenarios {
            let buffer = try Fixture3DurationFitting.createReplacementBuffer(for: scenario)
            let bufferSeconds = Double(buffer.frameLength) / buffer.format.sampleRate
            #expect(abs(bufferSeconds - scenario.durationSeconds) < 0.001)

            let wavURL = tempDirectory.appendingPathComponent("replacement_\(scenario).wav")
            let savedWAV = try Fixture3DurationFitting.createReplacementWAV(for: scenario, at: wavURL)
            #expect(FileManager.default.fileExists(atPath: savedWAV.path))
        }
    }

    @Test("Feature 47: Fixture 1 ground-truth cue time ranges and silence intervals")
    func test_feature47_fixture1_cue_structure() {
        let cues = Fixture1SingleTrack.groundTruthCues
        #expect(cues.count == 3)

        // Cue 1: [1.0s, 3.5s]
        #expect(CMTimeGetSeconds(cues[0].start) == 1.0)
        #expect(CMTimeGetSeconds(cues[0].duration) == 2.5)
        #expect(CMTimeGetSeconds(cues[0].end) == 3.5)

        // Cue 2: [4.5s, 7.5s]
        #expect(CMTimeGetSeconds(cues[1].start) == 4.5)
        #expect(CMTimeGetSeconds(cues[1].duration) == 3.0)
        #expect(CMTimeGetSeconds(cues[1].end) == 7.5)

        // Cue 3: [8.5s, 9.5s]
        #expect(CMTimeGetSeconds(cues[2].start) == 8.5)
        #expect(CMTimeGetSeconds(cues[2].duration) == 1.0)
        #expect(CMTimeGetSeconds(cues[2].end) == 9.5)

        // Silence gaps between cues:
        // [0.0s, 1.0s] = 1.0s room tone
        #expect(CMTimeGetSeconds(Fixture1SingleTrack.roomToneRange.duration) == 1.0)
        // [3.5s, 4.5s] = 1.0s gap between Cue 1 and Cue 2
        let gap1 = CMTimeSubtract(cues[1].start, cues[0].end)
        #expect(CMTimeGetSeconds(gap1) == 1.0)
        // [7.5s, 8.5s] = 1.0s gap between Cue 2 and Cue 3
        let gap2 = CMTimeSubtract(cues[2].start, cues[1].end)
        #expect(CMTimeGetSeconds(gap2) == 1.0)
    }

    @Test("Feature 47: Fixture 2 multi-track audio track specifications")
    func test_feature47_fixture2_specifications() {
        #expect(CMTimeCompare(Fixture2MultiTrack.duration, CMTime(value: 100, timescale: 10)) == 0)
        #expect(Fixture2MultiTrack.groundTruthCues.count == 3)
        #expect(CMTimeGetSeconds(Fixture2MultiTrack.roomToneRange.duration) == 1.0)
    }

    // MARK: - Feature 15: Project Bundle Serialization with Synthetic Assets (ADR 0004)

    @Test("Feature 15: Project bundle creation and APFS clone referencing Fixture 1")
    func test_feature15_bundle_with_fixture1_cloned() async throws {
        let fixtureURL = tempDirectory.appendingPathComponent("source_f1.mov")
        let asset = try await Fixture1SingleTrack.generate(at: fixtureURL)

        let bundleURL = tempDirectory.appendingPathComponent("ProjectF1.voicefix")
        let metadata = ProjectMetadata(
            name: "Fixture 1 Project",
            sourceStorageMode: .cloned(relativePath: "source.mov"),
            designatedNarrationTrackID: Int(asset.audioTrackIDs.first ?? 1),
            passthroughTrackIDs: [],
            totalDuration: asset.duration,
            cues: asset.expectedCues
        )

        let bundle = try ProjectBundle.create(at: bundleURL, metadata: metadata)
        #expect(FileManager.default.fileExists(atPath: bundle.projectJSONURL.path))

        // Save bundle
        try ProjectBundleSerializer.save(bundle: bundle)

        // Reload bundle and verify
        let loaded = try ProjectBundleSerializer.load(from: bundleURL)
        #expect(loaded.metadata.name == "Fixture 1 Project")
        #expect(loaded.cues.count == 3)
        #expect(CMTimeCompare(loaded.metadata.totalDuration, asset.duration) == 0)
        #expect(loaded.metadata.designatedNarrationTrackID == Int(asset.audioTrackIDs.first ?? 1))
    }

    @Test("Feature 15: Project bundle creation with Bookmark fallback referencing Fixture 2")
    func test_feature15_bundle_with_fixture2_bookmark() async throws {
        let fixtureURL = tempDirectory.appendingPathComponent("source_f2.mov")
        let asset = try await Fixture2MultiTrack.generate(at: fixtureURL)

        let bookmarkData = try BookmarkManager.createBookmark(for: fixtureURL)
        let bundleURL = tempDirectory.appendingPathComponent("ProjectF2.voicefix")

        let narrationID = Int(asset.audioTrackIDs[0])
        let passthroughID = Int(asset.audioTrackIDs[1])

        let metadata = ProjectMetadata(
            name: "Fixture 2 Multi-Track Project",
            sourceStorageMode: .externalBookmark(bookmarkData: bookmarkData, originalPath: fixtureURL.path),
            designatedNarrationTrackID: narrationID,
            passthroughTrackIDs: [passthroughID],
            totalDuration: asset.duration,
            cues: asset.expectedCues
        )

        let bundle = try ProjectBundle.create(at: bundleURL, metadata: metadata)
        try ProjectBundleSerializer.save(bundle: bundle)

        let loaded = try ProjectBundleSerializer.load(from: bundleURL)
        #expect(loaded.metadata.passthroughTrackIDs == [passthroughID])
        #expect(loaded.metadata.designatedNarrationTrackID == narrationID)

        // Resolve bookmark
        let resolved = try BookmarkManager.resolveBookmark(data: bookmarkData)
        #expect(resolved.url.resolvingSymlinksInPath().path == fixtureURL.resolvingSymlinksInPath().path)
    }

    @Test("Feature 15: Project bundle synthesized Cue WAV file persistence")
    func test_feature15_bundle_cue_wav_persistence() async throws {
        let bundleURL = tempDirectory.appendingPathComponent("CueAudioProject.voicefix")
        var cue = Cue(
            timeRange: CMTimeRange(start: CMTime(value: 10, timescale: 10), duration: CMTime(value: 20, timescale: 10)),
            text: "Testing cue WAV persistence"
        )

        let metadata = ProjectMetadata(
            name: "CueAudioProject",
            sourceStorageMode: .cloned(relativePath: "source.mov"),
            designatedNarrationTrackID: 1,
            totalDuration: CMTime(value: 50, timescale: 10),
            cues: [cue]
        )

        let bundle = try ProjectBundle.create(at: bundleURL, metadata: metadata)

        // Synthesize replacement audio and save to bundle cues directory
        let pcmBuffer = try SyntheticFixtureGenerator.createPCMBuffer(duration: cue.duration)
        let cueID = cue.id.uuidString
        let cueWAVURL = bundle.cuesAudioDirectoryURL.appendingPathComponent("cue_\(cueID).wav")
        try SyntheticFixtureGenerator.writeWAVFile(buffer: pcmBuffer, to: cueWAVURL)

        #expect(FileManager.default.fileExists(atPath: cueWAVURL.path))

        // Update cue reference
        cue.audioWAVRelativePath = "audio/cues/cue_\(cueID).wav"
        cue.editState = .synthesized

        var updatedBundle = bundle
        updatedBundle.cues = [cue]
        try ProjectBundleSerializer.save(bundle: updatedBundle)

        let reloaded = try ProjectBundleSerializer.load(from: bundleURL)
        #expect(reloaded.cues[0].editState == .synthesized)
        #expect(reloaded.cues[0].audioWAVRelativePath == "audio/cues/cue_\(cueID).wav")

        let resolvedCueURL = reloaded.rootURL.appendingPathComponent(reloaded.cues[0].audioWAVRelativePath!)
        #expect(FileManager.default.fileExists(atPath: resolvedCueURL.path))
    }

    @Test("Feature 15: Project metadata room tone path persistence")
    func test_feature15_room_tone_metadata_persistence() throws {
        let bundleURL = tempDirectory.appendingPathComponent("RoomToneProject.voicefix")
        let metadata = ProjectMetadata(
            name: "RoomToneProject",
            sourceStorageMode: .cloned(relativePath: "source.mov"),
            designatedNarrationTrackID: 1,
            totalDuration: CMTime(value: 100, timescale: 10),
            roomToneRelativePath: "room_tone.wav"
        )

        let bundle = try ProjectBundle.create(at: bundleURL, metadata: metadata)
        try ProjectBundleSerializer.save(bundle: bundle)

        let loaded = try ProjectBundleSerializer.load(from: bundleURL)
        #expect(loaded.metadata.roomToneRelativePath == "room_tone.wav")
    }

    @Test("Feature 15: Fixed-slot boundary immutability across project save/load cycle")
    func test_feature15_fixed_slot_invariance_on_save_load() throws {
        let cue1 = Cue(
            timeRange: CMTimeRange(start: CMTime(value: 0, timescale: 10), duration: CMTime(value: 20, timescale: 10)),
            text: "First cue"
        )
        let cue2 = Cue(
            timeRange: CMTimeRange(start: CMTime(value: 20, timescale: 10), duration: CMTime(value: 30, timescale: 10)),
            text: "Second cue"
        )

        let bundleURL = tempDirectory.appendingPathComponent("InvariantProject.voicefix")
        let metadata = ProjectMetadata(
            name: "InvariantProject",
            sourceStorageMode: .cloned(relativePath: "source.mov"),
            designatedNarrationTrackID: 1,
            totalDuration: CMTime(value: 50, timescale: 10),
            cues: [cue1, cue2]
        )

        let bundle = try ProjectBundle.create(at: bundleURL, metadata: metadata)

        // Mutate Cue 1 text and edit state
        var mutatedBundle = bundle
        mutatedBundle.cues[0].text = "Completely rewritten text that is much longer"
        mutatedBundle.cues[0].editState = .edited

        try ProjectBundleSerializer.save(bundle: mutatedBundle)

        let loaded = try ProjectBundleSerializer.load(from: bundleURL)

        // INVARIANT 1: Cue 2 boundaries MUST be strictly identical
        #expect(CMTimeCompare(loaded.cues[1].start, cue2.start) == 0, "Cue 2 start boundary moved after editing Cue 1!")
        #expect(CMTimeCompare(loaded.cues[1].end, cue2.end) == 0, "Cue 2 end boundary moved after editing Cue 1!")
        #expect(CMTimeCompare(loaded.cues[1].duration, cue2.duration) == 0, "Cue 2 duration changed after editing Cue 1!")
    }

    // MARK: - Feature 6: Fixed-Slot Invariant Engine (ADR 0001)

    @Test("Feature 6: Invariant 1 - Editing Cue N leaves Cue N+1 boundaries strictly identical")
    func test_feature6_invariant_adjacent_cues_unaffected() {
        var cues = Fixture1SingleTrack.groundTruthCues
        let originalCue2Start = cues[1].start
        let originalCue2End = cues[1].end
        let originalCue3Start = cues[2].start
        let originalCue3End = cues[2].end

        // Edit Cue 1 text
        cues[0].text = "This is a brand new replacement transcript text"
        cues[0].editState = .edited

        // Assert Cue 2 and Cue 3 untouched
        #expect(CMTimeCompare(cues[1].start, originalCue2Start) == 0)
        #expect(CMTimeCompare(cues[1].end, originalCue2End) == 0)
        #expect(CMTimeCompare(cues[2].start, originalCue3Start) == 0)
        #expect(CMTimeCompare(cues[2].end, originalCue3End) == 0)
    }

    @Test("Feature 6: Invariant 2 - Rational timestamp arithmetic precision without frame rounding")
    func test_feature6_rational_precision_no_rounding() {
        // High-resolution timescale (e.g. 44100 audio samples)
        let tStart = CMTime(value: 44101, timescale: 44100) // 1.0000226757... s
        let tDuration = CMTime(value: 88200, timescale: 44100) // 2.0 s
        let cue = Cue(timeRange: CMTimeRange(start: tStart, duration: tDuration), text: "Audio rate cue")

        #expect(cue.start.value == 44101)
        #expect(cue.start.timescale == 44100)
        #expect(cue.end.value == 132301)
        #expect(cue.end.timescale == 44100)
    }

    @Test("Feature 6: Multiple contiguous cues boundary invariance")
    func test_feature6_multiple_contiguous_cues() {
        var cues: [Cue] = []
        var currentTime = CMTime.zero
        let slotDuration = CMTime(value: 15, timescale: 10) // 1.5s each

        for i in 0..<5 {
            let cue = Cue(
                timeRange: CMTimeRange(start: currentTime, duration: slotDuration),
                text: "Cue #\(i)"
            )
            cues.append(cue)
            currentTime = CMTimeAdd(currentTime, slotDuration)
        }

        // Snapshot boundaries of Cue 1, 3, 4
        let snapshotCue1 = cues[1].timeRange
        let snapshotCue3 = cues[3].timeRange
        let snapshotCue4 = cues[4].timeRange

        // Mutate middle Cue 2
        cues[2].text = "Middle cue replaced"
        cues[2].editState = .synthesized

        #expect(cues[1].timeRange == snapshotCue1)
        #expect(cues[3].timeRange == snapshotCue3)
        #expect(cues[4].timeRange == snapshotCue4)
    }

    @Test("Feature 6: Cue edit state transitions preserve immutable timeRange")
    func test_feature6_edit_state_lifecycle_preserves_timerange() {
        let fixedRange = CMTimeRange(start: CMTime(value: 50, timescale: 10), duration: CMTime(value: 30, timescale: 10))
        var cue = Cue(timeRange: fixedRange, text: "Lifecycle test")

        let states: [CueEditState] = [.original, .edited, .synthesized, .overflowGated, .forceFitted]
        for state in states {
            cue.editState = state
            #expect(cue.timeRange == fixedRange)
            #expect(cue.start == fixedRange.start)
            #expect(cue.end == fixedRange.end)
            #expect(cue.duration == fixedRange.duration)
        }
    }

    @Test("Feature 6: Zero-gap cue splitting model mathematical invariant")
    func test_feature6_zero_gap_cue_splitting_invariants() {
        let parentStart = CMTime(value: 10, timescale: 10) // 1.0s
        let parentDuration = CMTime(value: 30, timescale: 10) // 3.0s -> ends at 4.0s
        let parentRange = CMTimeRange(start: parentStart, duration: parentDuration)
        let splitTime = CMTime(value: 24, timescale: 10) // 2.4s

        // Split produces: [parentStart, splitTime] and [splitTime, parentEnd]
        let childRangeA = CMTimeRange(start: parentStart, duration: CMTimeSubtract(splitTime, parentStart))
        let childRangeB = CMTimeRange(start: splitTime, duration: CMTimeSubtract(parentRange.end, splitTime))

        // INVARIANT 2: Zero gap, zero overlap
        #expect(CMTimeCompare(childRangeA.start, parentRange.start) == 0)
        #expect(CMTimeCompare(childRangeA.end, childRangeB.start) == 0, "Split boundary must have zero gap/overlap")
        #expect(CMTimeCompare(childRangeB.end, parentRange.end) == 0)

        let totalDuration = CMTimeAdd(childRangeA.duration, childRangeB.duration)
        #expect(CMTimeCompare(totalDuration, parentDuration) == 0, "Sum of child durations must exactly equal parent duration")
    }
}
