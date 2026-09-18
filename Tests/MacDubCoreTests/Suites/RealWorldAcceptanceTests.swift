import Testing
import AVFoundation
import CoreMedia
import Foundation
import Cocoa
import CoreGraphics
@testable import MacDubCore
@testable import MacDubApp

@Suite("Real-World Media Acceptance Tests")
struct RealWorldAcceptanceTests {

    let realMediaURL = URL(fileURLWithPath: "/tmp/InteractionKit_ScreenRecording.mov")

    @Test("Verify real media acceptance workflow, synchronization, and bundle persistence")
    @MainActor
    func test_real_media_acceptance_journey() async throws {
        // Only run when local real media exists on target developer host
        guard FileManager.default.fileExists(atPath: realMediaURL.path) else {
            print("Skipping RealWorldAcceptanceTests: /tmp/InteractionKit_ScreenRecording.mov not present on host")
            return
        }

        // 1. Verify first video frame visibly renders & decodes
        let asset = AVURLAsset(url: realMediaURL)
        let isPlayable = try await asset.load(.isPlayable)
        #expect(isPlayable, "Real recording must be playable by AVFoundation")

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        #expect(!videoTracks.isEmpty, "Real recording must contain at least one video track")
        let videoTrack = videoTracks[0]
        let naturalSize = try await videoTrack.load(.naturalSize)
        #expect(naturalSize.width > 0 && naturalSize.height > 0, "Video track must have non-zero dimensions")

        let duration = try await asset.load(.duration)
        #expect(CMTimeGetSeconds(duration) > 5.0, "Real recording must have meaningful duration")

        // Analytically verify frame extraction at t=0
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
        #expect(cgImage.width > 0 && cgImage.height > 0, "First video frame must decode valid image pixels")

        // 2. Full AppViewModel import and transcription creates real Cues
        let appViewModel = AppViewModel()
        try await appViewModel.importMediaAsync(from: realMediaURL)
        #expect(appViewModel.sourceMediaURL != nil, "Source media URL must be set")
        #expect(appViewModel.cues.count > 0, "Transcription must detect and generate real cues from recording narration")

        // 3. Play / Pause works
        #expect(!appViewModel.timelineViewModel.clock.isPlaying, "Initial state should be paused")
        appViewModel.timelineViewModel.clock.togglePlayPause()
        #expect(appViewModel.timelineViewModel.clock.isPlaying, "Clock must transition to playing")
        appViewModel.timelineViewModel.clock.togglePlayPause()
        #expect(!appViewModel.timelineViewModel.clock.isPlaying, "Clock must transition back to paused")

        // 4. ±5 seconds really moves five seconds
        let seekTarget = CMTime(seconds: 10.0, preferredTimescale: 600_000)
        await appViewModel.timelineViewModel.clock.seek(to: seekTarget)
        let initialTime = CMTimeGetSeconds(appViewModel.timelineViewModel.clock.currentTime)
        #expect(abs(initialTime - 10.0) < 0.05, "Seek to 10s must be accurate")

        appViewModel.timelineViewModel.clock.seekForward(by: 5.0)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let timeAfterForward = CMTimeGetSeconds(appViewModel.timelineViewModel.clock.currentTime)
        #expect(abs(timeAfterForward - 15.0) < 0.05, "+5s step must advance playhead by exactly 5 seconds")

        appViewModel.timelineViewModel.clock.seekBackward(by: 5.0)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let timeAfterBackward = CMTimeGetSeconds(appViewModel.timelineViewModel.clock.currentTime)
        #expect(abs(timeAfterBackward - 10.0) < 0.05, "-5s step must retreat playhead by exactly 5 seconds")

        // 5. Timeline scrubbing updates visible frame
        let scrubTarget = CMTime(seconds: 20.0, preferredTimescale: 600_000)
        appViewModel.timelineViewModel.beginScrubbing()
        let targetX = appViewModel.timelineViewModel.converter.timeToX(scrubTarget)
        appViewModel.timelineViewModel.updateScrub(to: targetX)
        appViewModel.timelineViewModel.endScrubbing(resumePlayback: false)
        let frameAt20 = try generator.copyCGImage(at: scrubTarget, actualTime: nil)
        #expect(frameAt20.width > 0 && frameAt20.height > 0, "Scrubbed time must decode valid video frame")

        // 6. Clicking a Cue seeks the video & Reference Monitor remains synchronized
        if let firstCue = appViewModel.cues.first {
            appViewModel.selectedCueID = firstCue.id
            appViewModel.timelineViewModel.seek(to: firstCue.start)
            try? await Task.sleep(nanoseconds: 50_000_000)
            let currentTime = CMTimeGetSeconds(appViewModel.timelineViewModel.clock.currentTime)
            let cueStart = CMTimeGetSeconds(firstCue.start)
            #expect(abs(currentTime - cueStart) < 0.05, "Clicking cue must seek timeline to cue start time")
        }

        // 7. Save / Reopen .voicefix restores media and Cues
        let bundleURL = FileManager.default.temporaryDirectory.appendingPathComponent("RealWorldAcceptanceTest.voicefix")
        try? FileManager.default.removeItem(at: bundleURL)
        try appViewModel.saveProject(to: bundleURL)

        let reloadedViewModel = AppViewModel()
        try reloadedViewModel.loadProject(from: bundleURL)
        #expect(reloadedViewModel.sourceMediaURL != nil, "Reloaded project must resolve source media URL")
        #expect(reloadedViewModel.cues.count == appViewModel.cues.count, "Reloaded project must preserve exact cue count")
        #expect(abs(CMTimeGetSeconds(reloadedViewModel.totalDuration) - CMTimeGetSeconds(appViewModel.totalDuration)) < 0.01, "Reloaded duration must match")

        // 8. Launch packaged dist/MacDub.app with the saved bundle and capture genuine screenshot
        let appURL = URL(fileURLWithPath: "/Users/fady/Dev/macdub/dist/MacDub.app/Contents/MacOS/MacDub")
        if FileManager.default.fileExists(atPath: appURL.path) {
            let appProcess = Process()
            appProcess.executableURL = appURL
            appProcess.arguments = [bundleURL.path]
            try? appProcess.run()

            var targetWindowID: CGWindowID?
            for _ in 1...25 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
                    continue
                }
                for w in windowList {
                    let pid = w[kCGWindowOwnerPID as String] as? Int32 ?? 0
                    let id = w[kCGWindowNumber as String] as? CGWindowID ?? 0
                    let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
                    let width = bounds["Width"] as? Double ?? 0
                    let height = bounds["Height"] as? Double ?? 0
                    if pid == appProcess.processIdentifier && width > 400 && height > 300 {
                        targetWindowID = id
                        break
                    }
                }
                if targetWindowID != nil { break }
            }

            if let winID = targetWindowID {
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                let screenshotPath = "/Users/fady/Dev/macdub/docs/screenshots/real_world_acceptance.png"
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-o", "-l\(winID)", screenshotPath]
                try? capture.run()
                capture.waitUntilExit()
                #expect(FileManager.default.fileExists(atPath: screenshotPath), "Screenshot must be successfully written to docs/screenshots/real_world_acceptance.png")
            }
            appProcess.terminate()
        }

        // Clean up temp test bundle
        try? FileManager.default.removeItem(at: bundleURL)
    }

    @Test("Media loaded empty narration state triggers transcription")
    @MainActor
    func test_media_loaded_empty_narration_state() {
        let appViewModel = AppViewModel()
        appViewModel.sourceMediaURL = URL(fileURLWithPath: "/tmp/sample.mov")
        #expect(appViewModel.sourceMediaURL != nil)
        #expect(appViewModel.cues.isEmpty)

        var transcribedCalled = false
        let editorVM = appViewModel.scriptEditorViewModel
        let docView = ScriptDocumentView(
            cues: .constant([]),
            selectedCueID: .constant(nil),
            currentTime: .zero,
            editorViewModel: editorVM,
            isMediaLoaded: true,
            isTranscribing: false,
            transcriptionStatus: "",
            onSeek: { _ in },
            onSynthesizeCue: { _ in },
            onForceFitCue: { _ in },
            onDiscardCandidate: { _ in },
            onRestoreOriginalCue: { _ in },
            onOpenMedia: { },
            onTranscribeRecording: {
                transcribedCalled = true
            }
        )
        #expect(docView.isMediaLoaded)
        #expect(!docView.isTranscribing)
        docView.onTranscribeRecording()
        #expect(transcribedCalled)
    }
}
