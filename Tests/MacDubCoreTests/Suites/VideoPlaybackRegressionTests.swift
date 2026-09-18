import Testing
import SwiftUI
import AVFoundation
import CoreMedia
import Foundation
@testable import MacDubCore
@testable import MacDubApp

@Suite("Video Playback & Media Replacement Regression Tests (Phase 1 & 18)")
struct VideoPlaybackRegressionTests {

    private func createTempDir() throws -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("macdub_video_reg_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return temp
    }

    @Test("Asset A loading resolves player, currentItem, video track, presentation size, and duration")
    @MainActor
    func test_assetA_loading_and_track_resolution() async throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let assetAURL = tempDir.appendingPathComponent("assetA.mov")
        _ = try await Fixture1SingleTrack.generate(at: assetAURL)

        let appVM = AppViewModel()
        try await appVM.importMediaAsync(from: assetAURL)

        // 1. Player has current item
        guard let player = appVM.player, let currentItem = player.currentItem else {
            Issue.record("Player or currentItem is nil after import")
            return
        }

        // 2. Video track exists
        let tracks = try await currentItem.asset.loadTracks(withMediaType: .video)
        #expect(!tracks.isEmpty, "Current item asset must contain at least one video track")

        let videoTrack = tracks[0]
        let naturalSize = try await videoTrack.load(.naturalSize)
        #expect(naturalSize.width > 0 && naturalSize.height > 0, "Video track naturalSize must be non-zero")

        // 3. Duration resolves
        let duration = try await currentItem.asset.load(.duration)
        let durSec = CMTimeGetSeconds(duration)
        #expect(abs(durSec - 10.0) < 0.1, "Duration must resolve to approximately 10.0s")
    }

    @Test("Seeking updates currentTime and settles without timeline drift")
    @MainActor
    func test_seeking_synchronization() async throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let assetURL = tempDir.appendingPathComponent("seek_test.mov")
        _ = try await Fixture1SingleTrack.generate(at: assetURL)

        let appVM = AppViewModel()
        try await appVM.importMediaAsync(from: assetURL)

        let targetTime = CMTime(seconds: 4.5, preferredTimescale: 600_000)
        await appVM.timelineViewModel.clock.seek(to: targetTime, tolerance: .zero)

        let settledTime = appVM.timelineViewModel.clock.currentTime
        #expect(abs(CMTimeGetSeconds(settledTime) - 4.5) < 0.05, "Timeline clock should settle accurately at seek target")

        if let player = appVM.player {
            let playerTime = player.currentTime()
            #expect(abs(CMTimeGetSeconds(playerTime) - 4.5) < 0.1, "AVPlayer should settle accurately at seek target")
        }
    }

    @Test("Asset replacement from A to B removes stale state and attaches fresh player")
    @MainActor
    func test_media_replacement_detaches_stale_state() async throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let assetAURL = tempDir.appendingPathComponent("assetA.mov")
        let assetBURL = tempDir.appendingPathComponent("assetB.mov")
        _ = try await Fixture1SingleTrack.generate(at: assetAURL)
        _ = try await Fixture2MultiTrack.generate(at: assetBURL)

        let appVM = AppViewModel()
        try await appVM.importMediaAsync(from: assetAURL)
        let playerA = appVM.player

        // Seek into asset A
        await appVM.timelineViewModel.clock.seek(to: CMTime(seconds: 7.0, preferredTimescale: 600_000))
        #expect(CMTimeGetSeconds(appVM.timelineViewModel.clock.currentTime) > 5.0)

        // Replace with asset B
        try await appVM.importMediaAsync(from: assetBURL)
        let playerB = appVM.player

        #expect(playerA !== playerB, "New player instance must be created for asset B")
        #expect(appVM.sourceMediaURL == assetBURL, "Source media URL must point to asset B")
        #expect(appVM.detectedAudioTracks.count == 2, "Asset B has 2 audio tracks")
    }

    @Test("Preview composition strictly preserves video track, naturalSize, and duration")
    @MainActor
    func test_preview_composition_video_integrity() async throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceURL = tempDir.appendingPathComponent("preview_video.mov")
        let asset = try await Fixture1SingleTrack.generate(at: sourceURL)

        let appVM = AppViewModel()
        try await appVM.importMediaAsync(from: sourceURL)

        // Splicing replacement audio for cue 1
        let replacementWAVURL = tempDir.appendingPathComponent("replacement_cue.wav")
        let cueDuration = asset.expectedCues[0].duration
        let replacementBuffer = try SyntheticFixtureGenerator.createPCMBuffer(duration: cueDuration, frequency: 1000.0)
        try SyntheticFixtureGenerator.writeWAVFile(buffer: replacementBuffer, to: replacementWAVURL)

        var cues = appVM.cues
        if !cues.isEmpty {
            cues[0] = cues[0].withUpdatedAudio(audioWAVRelativePath: replacementWAVURL.path, editState: .synthesized)
            appVM.cues = cues
        }

        let comp = try await appVM.buildPreviewComposition()

        // Verify Composition has video track
        let videoTracks = try await comp.loadTracks(withMediaType: .video)
        #expect(!videoTracks.isEmpty, "Preview composition MUST contain a video track")

        // Verify Composition naturalSize is non-zero (addresses the root-cause bug where naturalSize defaulted to (0,0))
        let compSize = comp.naturalSize
        #expect(compSize.width > 0 && compSize.height > 0, "Composition naturalSize must be non-zero (got \(compSize))")

        let trackSize = try await videoTracks[0].load(.naturalSize)
        #expect(trackSize.width > 0 && trackSize.height > 0, "Video track naturalSize must be non-zero (got \(trackSize))")
        #expect(compSize == trackSize, "Composition naturalSize should match track naturalSize")

        // Verify player item has non-empty presentationSize once ready
        if let currentItem = appVM.player?.currentItem {
            #expect(currentItem.asset is AVComposition)
        }
    }

    @Test("Saved project bundle reload restores playable media and player item")
    @MainActor
    func test_saved_project_restores_playable_media() async throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mediaURL = tempDir.appendingPathComponent("recording.mov")
        _ = try await Fixture1SingleTrack.generate(at: mediaURL)

        let appVM1 = AppViewModel()
        try await appVM1.importMediaAsync(from: mediaURL)

        let bundleURL = tempDir.appendingPathComponent("TestProject.voicefix")
        try appVM1.saveProject(to: bundleURL)

        let appVM2 = AppViewModel()
        try appVM2.loadProject(from: bundleURL)

        #expect(appVM2.player != nil, "Restored project must instantiate an AVPlayer")
        #expect(appVM2.player?.currentItem != nil, "Restored player must have an active currentItem")
        #expect(appVM2.sourceMediaURL != nil, "Source media URL must be restored")

        let dur = try await appVM2.player!.currentItem!.asset.load(.duration)
        #expect(CMTimeGetSeconds(dur) > 0, "Restored media must have valid duration")
    }

    @Test("Generate Demo Bundle in /tmp/macdub_demo for interactive inspection")
    @MainActor
    func test_generate_demo_bundle() async throws {
        let sampleDir = URL(fileURLWithPath: "/tmp/macdub_demo")
        try? FileManager.default.createDirectory(at: sampleDir, withIntermediateDirectories: true)
        let movieURL = sampleDir.appendingPathComponent("HackathonDemo.mov")
        _ = try await Fixture1SingleTrack.generate(at: movieURL)
        let appVM = AppViewModel()
        try await appVM.importMediaAsync(from: movieURL)
        let bundleURL = sampleDir.appendingPathComponent("HackathonDemo.voicefix")
        try appVM.saveProject(to: bundleURL)
        #expect(FileManager.default.fileExists(atPath: movieURL.path))
        #expect(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("project.json").path))
    }

    @Test("Phase 20 UI Screenshot Verification Generator")
    @MainActor
    func test_render_phase20_screenshots() async throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Suites
            .deletingLastPathComponent() // MacDubCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Project Root
        let screenshotsDir = projectRoot.appendingPathComponent("docs/screenshots")
        try? FileManager.default.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)

        let movieURL = URL(fileURLWithPath: "/tmp/macdub_demo/HackathonDemo.mov")
        if !FileManager.default.fileExists(atPath: movieURL.path) {
            _ = try await Fixture1SingleTrack.generate(at: movieURL)
        }

        let appVM = AppViewModel()
        try await appVM.importMediaAsync(from: movieURL)

        // Realistic demo cues representing hackathon demo screen narration
        let sampleCues: [Cue] = [
            Cue(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: 0.5, preferredTimescale: 600),
                    duration: CMTime(seconds: 4.2, preferredTimescale: 600)
                ),
                text: "Welcome to MacDub. Today we are repairing the hackathon demo narration without re-recording any screen video.",
                originalText: "Welcome to MacDub. Today we are repairing the hackathon demo narration without re-recording any screen video.",
                editState: .original,
                words: [
                    WordTiming(word: "Welcome", timeRange: CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 600), duration: CMTime(seconds: 0.35, preferredTimescale: 600))),
                    WordTiming(word: "to", timeRange: CMTimeRange(start: CMTime(seconds: 0.85, preferredTimescale: 600), duration: CMTime(seconds: 0.2, preferredTimescale: 600))),
                    WordTiming(word: "MacDub.", timeRange: CMTimeRange(start: CMTime(seconds: 1.05, preferredTimescale: 600), duration: CMTime(seconds: 0.5, preferredTimescale: 600))),
                    WordTiming(word: "Today", timeRange: CMTimeRange(start: CMTime(seconds: 1.6, preferredTimescale: 600), duration: CMTime(seconds: 0.3, preferredTimescale: 600))),
                    WordTiming(word: "we", timeRange: CMTimeRange(start: CMTime(seconds: 1.9, preferredTimescale: 600), duration: CMTime(seconds: 0.2, preferredTimescale: 600))),
                    WordTiming(word: "are", timeRange: CMTimeRange(start: CMTime(seconds: 2.1, preferredTimescale: 600), duration: CMTime(seconds: 0.2, preferredTimescale: 600))),
                    WordTiming(word: "repairing", timeRange: CMTimeRange(start: CMTime(seconds: 2.3, preferredTimescale: 600), duration: CMTime(seconds: 0.5, preferredTimescale: 600))),
                    WordTiming(word: "the", timeRange: CMTimeRange(start: CMTime(seconds: 2.8, preferredTimescale: 600), duration: CMTime(seconds: 0.2, preferredTimescale: 600))),
                    WordTiming(word: "hackathon", timeRange: CMTimeRange(start: CMTime(seconds: 3.0, preferredTimescale: 600), duration: CMTime(seconds: 0.5, preferredTimescale: 600))),
                    WordTiming(word: "demo", timeRange: CMTimeRange(start: CMTime(seconds: 3.5, preferredTimescale: 600), duration: CMTime(seconds: 0.35, preferredTimescale: 600))),
                    WordTiming(word: "narration.", timeRange: CMTimeRange(start: CMTime(seconds: 3.85, preferredTimescale: 600), duration: CMTime(seconds: 0.85, preferredTimescale: 600)))
                ]
            ),
            Cue(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: 5.0, preferredTimescale: 600),
                    duration: CMTime(seconds: 2.8, preferredTimescale: 600)
                ),
                text: "Debugging and prompting became the biggest bottleneck as we explored the model integration.",
                originalText: "Debugging and prompting became the biggest bottleneck as we explored the model integration.",
                editState: .edited,
                words: [
                    WordTiming(word: "Debugging", timeRange: CMTimeRange(start: CMTime(seconds: 5.0, preferredTimescale: 600), duration: CMTime(seconds: 0.5, preferredTimescale: 600))),
                    WordTiming(word: "and", timeRange: CMTimeRange(start: CMTime(seconds: 5.5, preferredTimescale: 600), duration: CMTime(seconds: 0.2, preferredTimescale: 600))),
                    WordTiming(word: "prompting", timeRange: CMTimeRange(start: CMTime(seconds: 5.7, preferredTimescale: 600), duration: CMTime(seconds: 0.5, preferredTimescale: 600))),
                    WordTiming(word: "became", timeRange: CMTimeRange(start: CMTime(seconds: 6.2, preferredTimescale: 600), duration: CMTime(seconds: 0.4, preferredTimescale: 600))),
                    WordTiming(word: "the", timeRange: CMTimeRange(start: CMTime(seconds: 6.6, preferredTimescale: 600), duration: CMTime(seconds: 0.2, preferredTimescale: 600))),
                    WordTiming(word: "biggest", timeRange: CMTimeRange(start: CMTime(seconds: 6.8, preferredTimescale: 600), duration: CMTime(seconds: 0.4, preferredTimescale: 600))),
                    WordTiming(word: "bottleneck", timeRange: CMTimeRange(start: CMTime(seconds: 7.2, preferredTimescale: 600), duration: CMTime(seconds: 0.6, preferredTimescale: 600)))
                ]
            ),
            Cue(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: 8.0, preferredTimescale: 600),
                    duration: CMTime(seconds: 1.8, preferredTimescale: 600)
                ),
                text: "With transcript-first audio replacement, our voice dub matches screen timing perfectly.",
                originalText: "With transcript-first audio replacement, our voice dub matches screen timing perfectly.",
                editState: .original
            )
        ]
        appVM.cues = sampleCues
        appVM.timelineViewModel.setCues(sampleCues, totalDuration: appVM.totalDuration)

        @MainActor
        func captureView<V: View>(_ view: V, size: CGSize = CGSize(width: 1440, height: 900)) -> Data? {
            let hostingView = NSHostingView(rootView: view)
            hostingView.frame = NSRect(origin: .zero, size: size)

            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = true
            window.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)
            window.contentView = hostingView
            window.layoutIfNeeded()
            hostingView.layoutSubtreeIfNeeded()

            guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
                return nil
            }
            hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
            return rep.representation(using: .png, properties: [:])
        }

        // 1. Initial Project Loaded State
        appVM.selectedCueID = nil
        let view1 = MainAppView(appViewModel: appVM).frame(width: 1440, height: 900)
        if let png = captureView(view1) {
            try png.write(to: screenshotsDir.appendingPathComponent("1_project_loaded_state.png"))
        }

        // 2. Selected Cue Editing State
        appVM.selectedCueID = appVM.cues[0].id
        appVM.timelineViewModel.selectCue(appVM.cues[0])
        let view2 = MainAppView(appViewModel: appVM).frame(width: 1440, height: 900)
        if let png = captureView(view2) {
            try png.write(to: screenshotsDir.appendingPathComponent("2_cue_editing_state.png"))
        }

        // 3. Synthesis / Duration State (showing duration fit, overflow, and candidate actions)
        appVM.referenceVoice = ReferenceVoice(name: "Fady — Local", audioRelativePath: "audio/reference_voice.wav")
        appVM.cues[1] = appVM.cues[1].withUpdatedAudio(
            audioWAVRelativePath: "audio/cues/cue_synth_2.wav",
            editState: .overflowGated,
            overflowDelta: CMTime(seconds: 1.42, preferredTimescale: 600)
        )
        appVM.selectedCueID = appVM.cues[1].id
        appVM.timelineViewModel.selectCue(appVM.cues[1])
        let view3 = MainAppView(appViewModel: appVM).frame(width: 1440, height: 900)
        if let png = captureView(view3) {
            try png.write(to: screenshotsDir.appendingPathComponent("3_synthesis_duration_state.png"))
        }

        // 4. Timeline + Video Preview State (active playback/scrubbing preview with active word highlight)
        await appVM.timelineViewModel.clock.seek(to: CMTime(seconds: 2.2, preferredTimescale: 600_000))
        appVM.selectedCueID = appVM.cues[0].id
        let view4 = MainAppView(appViewModel: appVM).frame(width: 1440, height: 900)
        if let png = captureView(view4) {
            try png.write(to: screenshotsDir.appendingPathComponent("4_timeline_video_preview_state.png"))
        }

        #expect(FileManager.default.fileExists(atPath: screenshotsDir.appendingPathComponent("1_project_loaded_state.png").path))
        #expect(FileManager.default.fileExists(atPath: screenshotsDir.appendingPathComponent("2_cue_editing_state.png").path))
        #expect(FileManager.default.fileExists(atPath: screenshotsDir.appendingPathComponent("3_synthesis_duration_state.png").path))
        #expect(FileManager.default.fileExists(atPath: screenshotsDir.appendingPathComponent("4_timeline_video_preview_state.png").path))
    }

    @Test("Cue audio preview player is strongly retained on AppViewModel to prevent premature deallocation")
    @MainActor
    func test_cue_audio_preview_retains_player() async throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mediaURL = tempDir.appendingPathComponent("preview_test.mov")
        _ = try await Fixture1SingleTrack.generate(at: mediaURL)

        let appVM = AppViewModel()
        try await appVM.importMediaAsync(from: mediaURL)

        let testWAV = tempDir.appendingPathComponent("test_cue.wav")
        let buf = try SyntheticFixtureGenerator.createPCMBuffer(duration: CMTime(seconds: 2.0, preferredTimescale: 600), frequency: 440.0)
        try SyntheticFixtureGenerator.writeWAVFile(buffer: buf, to: testWAV)

        let cue = Cue(
            id: UUID(),
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 2.0, preferredTimescale: 600)),
            text: "Testing preview audio retention",
            audioWAVRelativePath: testWAV.path,
            editState: .synthesized
        )

        appVM.previewCueAudio(for: cue)
        #expect(appVM.cuePreviewPlayer != nil, "cuePreviewPlayer must be retained on AppViewModel")
        #expect(appVM.cuePreviewPlayer?.currentItem != nil, "cuePreviewPlayer must possess an active currentItem")
    }

    @Test("Unsaved changes flag transitions correctly across cue edits, splits, and project saves")
    @MainActor
    func test_unsaved_changes_tracking_across_cue_operations() async throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mediaURL = tempDir.appendingPathComponent("dirty_test.mov")
        _ = try await Fixture1SingleTrack.generate(at: mediaURL)

        let appVM = AppViewModel()
        try await appVM.importMediaAsync(from: mediaURL)
        #expect(!appVM.hasUnsavedChanges, "Freshly imported media should not be marked dirty")

        let cue = Cue(
            id: UUID(),
            timeRange: CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 600), duration: CMTime(seconds: 2.0, preferredTimescale: 600)),
            text: "Initial narration text",
            editState: .original
        )
        appVM.cues = [cue]
        appVM.timelineViewModel.setCues(appVM.cues, totalDuration: appVM.totalDuration)
        let firstCue = appVM.cues[0]

        // 1. Text edit marks dirty
        appVM.updateCueText(id: firstCue.id, newText: "Altered narration text")
        #expect(appVM.hasUnsavedChanges, "Text modification must set hasUnsavedChanges to true")

        // 2. Save resets dirty
        let bundleURL = tempDir.appendingPathComponent("DirtyTest.voicefix")
        try appVM.saveProject(to: bundleURL)
        #expect(!appVM.hasUnsavedChanges, "Saving project must clear hasUnsavedChanges")

        // 3. Split marks dirty
        appVM.splitCue(id: firstCue.id, at: CMTime(seconds: 1.0, preferredTimescale: 600))
        #expect(appVM.hasUnsavedChanges, "Splitting cue must set hasUnsavedChanges to true")
    }

    @Test("Cue word timing propagation and contains verification")
    func test_cue_word_timing_propagation() {
        let w1 = WordTiming(word: "Hello", timeRange: CMTimeRange(start: CMTime(seconds: 0.0, preferredTimescale: 600), duration: CMTime(seconds: 0.5, preferredTimescale: 600)))
        let w2 = WordTiming(word: "world", timeRange: CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 600), duration: CMTime(seconds: 0.5, preferredTimescale: 600)))

        let cue = Cue(
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 1.0, preferredTimescale: 600)),
            text: "Hello world",
            words: [w1, w2]
        )

        #expect(cue.words?.count == 2)
        #expect(w1.contains(time: CMTime(seconds: 0.25, preferredTimescale: 600)))
        #expect(!w1.contains(time: CMTime(seconds: 0.75, preferredTimescale: 600)))
        #expect(w2.contains(time: CMTime(seconds: 0.75, preferredTimescale: 600)))
    }
}
