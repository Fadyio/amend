import Testing
import AVFoundation
import CoreMedia
import Foundation
@testable import MacDubCore
@testable import MacDubApp

@Suite("Gate A, C, J, K: Deterministic Assembled User Journey Tests (Composition, Persistence & Export)")
struct AssembledAppE2ETests {

    private func createTempDir() throws -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return temp
    }

    private func countZeroCrossings(in buffer: AVAudioPCMBuffer, startSec: Double, durationSec: Double) -> Int {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let sr = buffer.format.sampleRate
        let startFrame = Int(startSec * sr)
        let endFrame = min(Int(buffer.frameLength), Int((startSec + durationSec) * sr))
        guard endFrame > startFrame + 1 else { return 0 }
        var crossings = 0
        for i in (startFrame + 1)..<endFrame {
            let prev = channel[i - 1]
            let curr = channel[i]
            if (prev < 0 && curr >= 0) || (prev > 0 && curr <= 0) {
                crossings += 1
            }
        }
        return crossings
    }

    private func computeMeanAbsoluteDifference(bufferA: AVAudioPCMBuffer, bufferB: AVAudioPCMBuffer) -> Float {
        guard let dataA = bufferA.floatChannelData?[0],
              let dataB = bufferB.floatChannelData?[0] else { return 0.0 }
        let count = min(Int(bufferA.frameLength), Int(bufferB.frameLength))
        guard count > 0 else { return 0.0 }
        var sum: Float = 0.0
        for i in 0..<count {
            sum += abs(dataA[i] - dataB[i])
        }
        return sum / Float(count)
    }

    struct TestFrequencySynthesizer: VoiceSynthesisProvider, Sendable {
        let providerType: SynthesisProviderType = .pocketTTS
        let frequency: Double

        func synthesize(
            text: String,
            voiceID: String? = nil,
            referenceAudioURL: URL? = nil
        ) async throws -> AVAudioPCMBuffer {
            // Generate deterministic sine buffer of 2.0s duration (speech length < 2.5s cue slot)
            return try SyntheticFixtureGenerator.createPCMBuffer(
                duration: CMTime(seconds: 2.0, preferredTimescale: 600),
                frequency: frequency,
                sampleRate: 44100.0
            )
        }
    }

    @Test("Deterministic assembled 16-step user journey: media import, track routing, injected audio, fitting, bundle save/reload, preview, bitstream export")
    @MainActor
    func test_complete_sixteen_step_assembled_user_journey() async throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // -------------------------------------------------------------------------
        // Step 1: Create two-track fixture
        // Track 1 (Narration): Cue 1 (440Hz, 1.0-3.5s), Cue 2 (880Hz, 4.5-7.5s), Cue 3 (440Hz, 8.5-9.5s)
        // Track 2 (Passthrough): Continuous 220Hz
        // -------------------------------------------------------------------------
        let sourceURL = tempDir.appendingPathComponent("e2e_source.mov")
        let asset = try await Fixture2MultiTrack.generate(at: sourceURL)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(asset.audioTrackIDs.count == 2)
        let narrationTrackID = asset.audioTrackIDs[0]
        let passthroughTrackID = asset.audioTrackIDs[1]

        // -------------------------------------------------------------------------
        // Step 2: Initialize AppViewModel with deterministic cue generator
        // -------------------------------------------------------------------------
        let silenceDetector = EnergySilenceDetector(minSilenceDuration: 0.2, speechPadding: 0.05, energyThresholdDB: -40.0)
        let mockASR = MockTranscriptionService(scriptedTimings: [
            WordTiming(word: "Introductory", timeRange: CMTimeRange(start: CMTime(seconds: 1.2, preferredTimescale: 600), duration: CMTime(seconds: 1.0, preferredTimescale: 600))),
            WordTiming(word: "Middle", timeRange: CMTimeRange(start: CMTime(seconds: 5.0, preferredTimescale: 600), duration: CMTime(seconds: 1.5, preferredTimescale: 600))),
            WordTiming(word: "Conclusion", timeRange: CMTimeRange(start: CMTime(seconds: 8.7, preferredTimescale: 600), duration: CMTime(seconds: 0.5, preferredTimescale: 600)))
        ])
        let cueGenerator = CueGenerator(silenceDetector: silenceDetector, transcriptionService: mockASR)
        let appViewModel = AppViewModel(cueGenerator: cueGenerator)

        #expect(appViewModel.sourceMediaURL == nil)
        #expect(appViewModel.cues.isEmpty)

        // -------------------------------------------------------------------------
        // Step 3: Import media into AppViewModel
        // -------------------------------------------------------------------------
        try await appViewModel.importMediaAsync(from: sourceURL)

        #expect(appViewModel.sourceMediaURL == sourceURL)
        #expect(appViewModel.detectedAudioTracks.count == 2)
        #expect(appViewModel.showTrackPicker == true, "Multi-track media must trigger TrackPicker modal (ADR-0003)")
        #expect(!appViewModel.isSingleTrackAdvisory)
        #expect(abs(CMTimeGetSeconds(appViewModel.totalDuration) - 10.0) < 0.05)

        // -------------------------------------------------------------------------
        // Step 4: Select Narration track (Track 1) and passthrough track (Track 2)
        // -------------------------------------------------------------------------
        appViewModel.designatedNarrationID = Int(narrationTrackID)
        appViewModel.passthroughTrackIDs = [Int(passthroughTrackID)]

        // -------------------------------------------------------------------------
        // Step 5: Confirm track configuration & Generate speech cues
        // -------------------------------------------------------------------------
        try await appViewModel.confirmTrackPickerAsync()

        #expect(!appViewModel.showTrackPicker)
        #expect(appViewModel.cues.count == 3, "Expected 3 detected speech cues in Track 1")
        #expect(appViewModel.timelineViewModel.cues.count == 3)
        let firstCue = appViewModel.cues[0]
        #expect(firstCue.text == "Introductory")
        #expect(abs(CMTimeGetSeconds(firstCue.timeRange.start) - 1.0) < 0.2)
        #expect(abs(CMTimeGetSeconds(firstCue.timeRange.duration) - 2.5) < 0.2)

        // -------------------------------------------------------------------------
        // Step 6: Edit Cue text
        // -------------------------------------------------------------------------
        let cue1ID = firstCue.id
        let updatedText = "Synthesized replacement line with pristine clarity"
        appViewModel.cues[0] = firstCue.withUpdatedText(updatedText)
        #expect(appViewModel.cues[0].text == updatedText)
        #expect(appViewModel.cues[0].editState == .edited)

        // -------------------------------------------------------------------------
        // Step 7: Synthesize replacement audio with a deterministic test provider (1200Hz)
        // -------------------------------------------------------------------------
        let replacementSynthesizer = TestFrequencySynthesizer(frequency: 1200.0)
        try await appViewModel.synthesizeCue(id: cue1ID, customProvider: replacementSynthesizer)

        // -------------------------------------------------------------------------
        // Step 8: Fit duration with room tone
        // -------------------------------------------------------------------------
        #expect(appViewModel.cues[0].editState == .synthesized)
        guard let relWAVPath = appViewModel.cues[0].audioWAVRelativePath else {
            #expect(Bool(false), "Synthesized cue must have audioWAVRelativePath set")
            return
        }
        #expect(relWAVPath.hasPrefix("audio/cues/cue_"))
        let sessionWAVURL = appViewModel.sessionWorkingDir.appendingPathComponent(relWAVPath)
        #expect(FileManager.default.fileExists(atPath: sessionWAVURL.path), "WAV must exist in session working directory")

        // -------------------------------------------------------------------------
        // Step 9: Save project via appViewModel.saveProject(to: bundleURL)
        // -------------------------------------------------------------------------
        let bundleURL = tempDir.appendingPathComponent("E2E_TestProject.voicefix")
        try appViewModel.saveProject(to: bundleURL)

        // -------------------------------------------------------------------------
        // Step 10: Verify .voicefix bundle on disk (project.json, audio/cues/cue_<UUID>.wav)
        // -------------------------------------------------------------------------
        #expect(FileManager.default.fileExists(atPath: bundleURL.path))
        let projectJSONURL = bundleURL.appendingPathComponent("project.json")
        #expect(FileManager.default.fileExists(atPath: projectJSONURL.path))
        let bundleWAVURL = bundleURL.appendingPathComponent(relWAVPath)
        #expect(FileManager.default.fileExists(atPath: bundleWAVURL.path), "Cue WAV must be migrated to bundle audio/cues directory")

        // Verify project.json content
        let projectData = try Data(contentsOf: projectJSONURL)
        let decodedBundle = try ProjectBundleSerializer.makeDecoder().decode(ProjectMetadata.self, from: projectData)
        #expect(decodedBundle.cues.count == 3)
        #expect(decodedBundle.cues[0].id == cue1ID)
        #expect(decodedBundle.cues[0].text == updatedText)
        #expect(decodedBundle.cues[0].editState == .synthesized)

        // -------------------------------------------------------------------------
        // Step 11: Initialize fresh AppViewModel and call loadProject(from: bundleURL)
        // -------------------------------------------------------------------------
        let reloadedViewModel = AppViewModel(cueGenerator: cueGenerator)
        try reloadedViewModel.loadProject(from: bundleURL)

        // -------------------------------------------------------------------------
        // Step 12: Verify reloaded cues, time ranges, and generated WAV paths exist
        // -------------------------------------------------------------------------
        #expect(reloadedViewModel.sourceMediaURL != nil)
        #expect(FileManager.default.fileExists(atPath: reloadedViewModel.sourceMediaURL!.path))
        #expect(reloadedViewModel.sourceMediaURL == bundleURL.appendingPathComponent("source.mov"))
        #expect(reloadedViewModel.projectBundleURL == bundleURL)
        #expect(reloadedViewModel.designatedNarrationID == Int(narrationTrackID))
        #expect(reloadedViewModel.passthroughTrackIDs.contains(Int(passthroughTrackID)))
        #expect(reloadedViewModel.cues.count == 3)
        #expect(reloadedViewModel.cues[0].id == cue1ID)
        #expect(reloadedViewModel.cues[0].text == updatedText)
        #expect(reloadedViewModel.cues[0].editState == .synthesized)
        #expect(reloadedViewModel.cues[0].audioWAVRelativePath == relWAVPath)
        let reloadedWAVURL = bundleURL.appendingPathComponent(reloadedViewModel.cues[0].audioWAVRelativePath!)
        #expect(FileManager.default.fileExists(atPath: reloadedWAVURL.path))

        // -------------------------------------------------------------------------
        // Step 13: Build preview playback composition
        // -------------------------------------------------------------------------
        let previewComp = try await reloadedViewModel.buildPreviewComposition()
        let previewDur = try await previewComp.load(.duration)
        #expect(abs(CMTimeGetSeconds(previewDur) - 10.0) < 0.05)

        let previewVideoTracks = try await previewComp.loadTracks(withMediaType: .video)
        #expect(previewVideoTracks.count == 1)

        let previewAudioTracks = try await previewComp.loadTracks(withMediaType: .audio)
        #expect(previewAudioTracks.count == 2)

        // -------------------------------------------------------------------------
        // Step 14: Export using PassthroughExportPipeline via ExportSheetViewModel
        // -------------------------------------------------------------------------
        let exportedMovieURL = tempDir.appendingPathComponent("e2e_final_export.mov")
        reloadedViewModel.prepareExport()
        guard let exportVM = reloadedViewModel.exportSheetViewModel else {
            #expect(Bool(false), "ExportSheetViewModel should be initialized")
            return
        }
        exportVM.destinationURL = exportedMovieURL
        let exportResult = try await exportVM.startExportAsync()

        #expect(FileManager.default.fileExists(atPath: exportedMovieURL.path))
        #expect(!exportResult.wasVideoReencoded, "Video must be remuxed without decoding or re-encoding (ADR-0008)")
        #expect(exportResult.videoSampleCount > 0)
        #expect(exportVM.exportProgress == 1.0)

        // -------------------------------------------------------------------------
        // Step 15: Decode exported audio and analytically verify replacement in target interval and untouched in passthrough
        // -------------------------------------------------------------------------
        let exportedAsset = AVURLAsset(url: exportedMovieURL)
        let exportedAudio = try await exportedAsset.loadTracks(withMediaType: .audio)
        #expect(exportedAudio.count == 2, "Exported movie must contain 2 audio tracks (narration + passthrough)")

        let extractor = AudioTrackExtractor()
        // Passthrough track is exportedAudio.first (untouched 220Hz)
        let passthroughPCM = try await extractor.extractPCMBuffer(
            from: exportedAsset,
            trackID: exportedAudio.first!.trackID,
            targetSampleRate: 16000.0
        )
        // Rebuilt narration track is exportedAudio.last (contains 1200Hz replacement)
        let narrationPCM = try await extractor.extractPCMBuffer(
            from: exportedAsset,
            trackID: exportedAudio.last!.trackID,
            targetSampleRate: 16000.0
        )

        #expect(narrationPCM.frameLength > 0)
        #expect(passthroughPCM.frameLength > 0)

        // Cue 1 interval (1.5 - 2.5s) contains 1200Hz replacement audio -> ~2400 zero-crossings/sec
        let cue1Crossings = countZeroCrossings(in: narrationPCM, startSec: 1.5, durationSec: 1.0)
        // Cue 2 interval (5.0 - 6.0s) contains original untouched 880Hz audio -> ~1760 zero-crossings/sec
        let cue2Crossings = countZeroCrossings(in: narrationPCM, startSec: 5.0, durationSec: 1.0)

        #expect(cue1Crossings >= 2100 && cue1Crossings <= 2700, "Exported Cue 1 must contain 1200Hz replacement audio (got \(cue1Crossings) zero crossings)")
        #expect(cue2Crossings >= 1600 && cue2Crossings <= 1920, "Exported Cue 2 must retain original 880Hz audio (got \(cue2Crossings) zero crossings)")
        #expect(cue1Crossings > cue2Crossings, "Replacement 1200Hz audio must have higher frequency than original 880Hz audio")

        // Passthrough track (continuous 220Hz audio -> ~440 crossings in 1s)
        let passCrossings = countZeroCrossings(in: passthroughPCM, startSec: 2.0, durationSec: 1.0)
        #expect(passCrossings >= 400 && passCrossings <= 480, "Exported passthrough track must preserve continuous 220Hz audio (got \(passCrossings) zero crossings)")

        // -------------------------------------------------------------------------
        // Step 16: Run CredentialLeakScanner on .voicefix bundle and output to verify zero credentials exist
        // -------------------------------------------------------------------------
        let leakScanner = CredentialLeakScanner()
        let violations = try leakScanner.scan(bundleURL: bundleURL)
        #expect(violations.isEmpty, "Project bundle must contain zero credential violations, found: \(violations)")

        let jsonViolations = try leakScanner.scan(projectJSONData: projectData)
        #expect(jsonViolations.isEmpty, "project.json must contain zero credential violations, found: \(jsonViolations)")
    }

    @Test("Single-track import presents advisory alert and automatic cue generation without modal gating")
    @MainActor
    func test_single_track_advisory_import_and_cue_generation() async throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceURL = tempDir.appendingPathComponent("single_track.mov")
        let asset = try await Fixture1SingleTrack.generate(at: sourceURL)

        let silenceDetector = EnergySilenceDetector(minSilenceDuration: 0.2, speechPadding: 0.05, energyThresholdDB: -40.0)
        let mockASR = MockTranscriptionService(scriptedTimings: [
            WordTiming(word: "Solo", timeRange: CMTimeRange(start: CMTime(seconds: 1.5, preferredTimescale: 600), duration: CMTime(seconds: 1.0, preferredTimescale: 600)))
        ])
        let cueGenerator = CueGenerator(silenceDetector: silenceDetector, transcriptionService: mockASR)
        let appViewModel = AppViewModel(cueGenerator: cueGenerator)

        try await appViewModel.importMediaAsync(from: sourceURL)

        #expect(appViewModel.isSingleTrackAdvisory == true)
        #expect(appViewModel.showTrackPicker == false)
        #expect(appViewModel.designatedNarrationID == Int(asset.audioTrackIDs[0]))
        #expect(appViewModel.passthroughTrackIDs.isEmpty)
        #expect(appViewModel.cues.count == 3)
    }

    @Test("AppViewModel cue splitting preserves timeline continuity and sync invariants")
    @MainActor
    func test_cue_splitting_in_app_view_model() async throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceURL = tempDir.appendingPathComponent("split_source.mov")
        let _ = try await Fixture1SingleTrack.generate(at: sourceURL)

        let silenceDetector = EnergySilenceDetector(minSilenceDuration: 0.2, speechPadding: 0.05, energyThresholdDB: -40.0)
        let mockASR = MockTranscriptionService(scriptedTimings: [
            WordTiming(word: "Compound sentence part one", timeRange: CMTimeRange(start: CMTime(seconds: 1.5, preferredTimescale: 600), duration: CMTime(seconds: 1.0, preferredTimescale: 600)))
        ])
        let cueGenerator = CueGenerator(silenceDetector: silenceDetector, transcriptionService: mockASR)
        let appViewModel = AppViewModel(cueGenerator: cueGenerator)

        try await appViewModel.importMediaAsync(from: sourceURL)
        #expect(appViewModel.cues.count == 3)

        let cueToSplit = appViewModel.cues[0]
        let splitTime = CMTime(seconds: 2.5, preferredTimescale: 600)
        appViewModel.splitCue(id: cueToSplit.id, at: splitTime)

        #expect(appViewModel.cues.count == 4)
        #expect(appViewModel.timelineViewModel.cues.count == 4)

        let cueA = appViewModel.cues[0]
        let cueB = appViewModel.cues[1]
        #expect(cueA.timeRange.end == cueB.timeRange.start)
        #expect(cueA.timeRange.start == cueToSplit.timeRange.start)
        #expect(cueB.timeRange.end == cueToSplit.timeRange.end)
    }

    @Test("Live-Model End-to-End Acceptance Journey: Parakeet ASR + Silero VAD + PocketTTS Cloning (Opt-in)")
    @MainActor
    func test_live_model_end_to_end_journey() async throws {
        guard ProcessInfo.processInfo.environment["MACDUB_RUN_LOCAL_AI_TESTS"] == "1" else {
            print("[NOTICE] Live model end-to-end journey skipped. Run with MACDUB_RUN_LOCAL_AI_TESTS=1 on Apple Silicon Mac to execute full neural pipeline.")
            return
        }

        guard let humanSpeechURL = TestReferenceVoiceResolver.resolveReferenceVoiceURL(filePath: #filePath) else {
            #expect(Bool(false), "Authentic human speech fixture human_speech_reference.wav could not be resolved from repository or MACDUB_TEST_REFERENCE_VOICE")
            return
        }

        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Generate synthetic multi-track media fixture with real human speech on narration track (Track 1)
        let sourceURL = tempDir.appendingPathComponent("live_source.mov")
        let asset = try await SyntheticFixtureGenerator.createMovie(
            at: sourceURL,
            duration: CMTime(seconds: 5.5, preferredTimescale: 600),
            audioTracks: [
                SyntheticAudioTrackSpec(
                    trackName: "Narration",
                    segments: [
                        .silence(duration: CMTime(seconds: 0.5, preferredTimescale: 600)),
                        .audioFile(url: humanSpeechURL, duration: CMTime(seconds: 4.5, preferredTimescale: 600)),
                        .silence(duration: CMTime(seconds: 0.5, preferredTimescale: 600))
                    ]
                ),
                SyntheticAudioTrackSpec(
                    trackName: "BackgroundMusic",
                    segments: [
                        .sineTone(frequency: 220.0, amplitude: 0.2, duration: CMTime(seconds: 5.5, preferredTimescale: 600))
                    ]
                )
            ]
        )

        // Initialize real AppViewModel with production CueGenerator (real Silero VAD + Parakeet)
        let appViewModel = AppViewModel()
        try await appViewModel.importMediaAsync(from: sourceURL)
        appViewModel.designatedNarrationID = Int(asset.audioTrackIDs[0])
        appViewModel.passthroughTrackIDs = [Int(asset.audioTrackIDs[1])]
        try await appViewModel.confirmTrackPickerAsync()

        // Verify VAD & ASR produced non-empty speech cues
        #expect(!appViewModel.cues.isEmpty, "VAD and ASR must detect and produce at least 1 speech cue from human speech fixture")
        guard let firstCue = appViewModel.cues.first else {
            #expect(Bool(false), "Cues array must have at least one cue")
            return
        }
        let fullTranscribedText = appViewModel.cues.map(\.text).joined(separator: " ").lowercased()
        #expect(!fullTranscribedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "ASR must transcribe non-empty text")
        let recognizedExpectedWords = ["exciting", "time", "week", "thursday", "eighteenth"].filter { fullTranscribedText.contains($0) }
        #expect(!recognizedExpectedWords.isEmpty, "ASR transcription must recognize meaningful words from Kathleen fixture (transcribed: '\(fullTranscribedText)', matched: \(recognizedExpectedWords))")

        // Configure authentic Reference Voice
        try appViewModel.setReferenceVoice(name: "Human Speaker", audioURL: humanSpeechURL)
        #expect(appViewModel.referenceVoice?.pocketTTSStatus == .configured)

        // 1. Choose or rewrite a deliberately short Cue sentence expected to fit its Cue duration
        let shortSentence = "Exciting time."
        appViewModel.cues[0] = appViewModel.cues[0].withUpdatedText(shortSentence)
        appViewModel.timelineViewModel.setCues(appViewModel.cues, totalDuration: appViewModel.totalDuration)

        // 2. Synthesize with real PocketTTS
        try await appViewModel.synthesizeCue(id: firstCue.id, providerType: .pocketTTS)

        // 3. Require the Cue to become an APPROVED active replacement, not merely .overflowGated
        // 4. If it unexpectedly overflows, explicitly resolve it using the production workflow
        if appViewModel.cues[0].editState == .overflowGated {
            try await appViewModel.forceFitCue(id: firstCue.id)
        }
        #expect(appViewModel.cues[0].editState == .synthesized || appViewModel.cues[0].editState == .forceFitted, "Cue must become an approved active replacement")
        #expect(appViewModel.cues[0].audioWAVRelativePath != nil, "Synthesized active audio WAV relative path must exist")
        #expect(appViewModel.cues[0].candidateAudioWAVRelativePath == nil, "Pending candidate audio must be cleared upon approval")
        #expect(appViewModel.referenceVoice?.pocketTTSStatus == .ready, "PocketTTS status must be .ready after successful synthesis")

        // 5. Build preview
        let previewComp = try await appViewModel.buildPreviewComposition()
        let previewAudioTracks = try await previewComp.loadTracks(withMediaType: .audio)
        #expect(!previewAudioTracks.isEmpty, "Preview composition must contain audio tracks")

        // 6. Export with passthrough pipeline
        let exportURL = tempDir.appendingPathComponent("live_exported.mov")
        let pipeline = PassthroughExportPipeline()
        let config = PassthroughExportConfig(
            sourceURL: sourceURL,
            destinationURL: exportURL,
            designatedNarrationTrackID: asset.audioTrackIDs[0],
            passthroughTrackIDs: [asset.audioTrackIDs[1]],
            cues: appViewModel.cues,
            bundleRootURL: appViewModel.sessionWorkingDir
        )
        let exportResult = try await pipeline.export(config: config)
        #expect(FileManager.default.fileExists(atPath: exportResult.outputURL.path))

        let exportedAsset = AVURLAsset(url: exportResult.outputURL)
        let exportedTracks = try await exportedAsset.loadTracks(withMediaType: .audio)
        #expect(exportedTracks.count == 2, "Exported movie must contain exactly 2 audio tracks (passthrough + narration)")

        let sourceAsset = AVURLAsset(url: sourceURL)
        let extractor = AudioTrackExtractor()

        // 7. Deterministically classify exported audio tracks without assuming array ordering
        let untouchedTimeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 0.4, preferredTimescale: 600))
        let originalUntouchedPCM = try await extractor.extractPCMBuffer(
            from: sourceAsset,
            trackID: asset.audioTrackIDs[0],
            timeRange: untouchedTimeRange,
            targetSampleRate: 16000.0,
            targetChannels: 1
        )
        let sourcePassthroughPCM = try await extractor.extractPCMBuffer(
            from: sourceAsset,
            trackID: asset.audioTrackIDs[1],
            targetSampleRate: 16000.0
        )

        var resolvedPassthroughTrack: AVAssetTrack?
        var resolvedNarrationTrack: AVAssetTrack?

        for track in exportedTracks {
            let candidateFullPCM = try await extractor.extractPCMBuffer(
                from: exportedAsset,
                trackID: track.trackID,
                targetSampleRate: 16000.0
            )
            let passDiff = computeMeanAbsoluteDifference(bufferA: candidateFullPCM, bufferB: sourcePassthroughPCM)
            let candidateCrossings = countZeroCrossings(in: candidateFullPCM, startSec: 1.0, durationSec: 1.0)

            // Passthrough track exhibits continuous 220Hz tone (~440 zero-crossings/sec) and bit/sample identity with source
            if passDiff < 0.001 && candidateCrossings >= 400 && candidateCrossings <= 480 {
                #expect(resolvedPassthroughTrack == nil, "Deterministically detected duplicate passthrough track")
                resolvedPassthroughTrack = track
            } else {
                // Narration track candidate: untouched interval outside Cue must match original narration source
                let candidateUntouchedPCM = try await extractor.extractPCMBuffer(
                    from: exportedAsset,
                    trackID: track.trackID,
                    timeRange: untouchedTimeRange,
                    targetSampleRate: 16000.0,
                    targetChannels: 1
                )
                let untouchedDiff = computeMeanAbsoluteDifference(bufferA: originalUntouchedPCM, bufferB: candidateUntouchedPCM)
                if untouchedDiff < 0.001 {
                    #expect(resolvedNarrationTrack == nil, "Deterministically detected duplicate narration track")
                    resolvedNarrationTrack = track
                }
            }
        }

        // Verify both tracks were deterministically identified and no unintended track was substituted
        guard let passthroughTrack = resolvedPassthroughTrack,
              let narrationTrack = resolvedNarrationTrack else {
            #expect(Bool(false), "Failed to deterministically identify Narration and Passthrough tracks from exported audio tracks")
            return
        }
        #expect(passthroughTrack.trackID != narrationTrack.trackID, "Narration and Passthrough tracks must be distinct audio tracks")

        // 8. Analytically verify that the exported Narration interval differs from the original Narration interval
        let cueTimeRange = appViewModel.cues[0].timeRange
        let originalCuePCM = try await extractor.extractPCMBuffer(
            from: sourceAsset,
            trackID: asset.audioTrackIDs[0],
            timeRange: cueTimeRange,
            targetSampleRate: 16000.0,
            targetChannels: 1
        )
        let exportedNarrationPCM = try await extractor.extractPCMBuffer(
            from: exportedAsset,
            trackID: narrationTrack.trackID,
            timeRange: cueTimeRange,
            targetSampleRate: 16000.0,
            targetChannels: 1
        )
        #expect(originalCuePCM.frameLength > 0)
        #expect(exportedNarrationPCM.frameLength > 0)
        let cueDiff = computeMeanAbsoluteDifference(bufferA: originalCuePCM, bufferB: exportedNarrationPCM)
        #expect(cueDiff > 0.005, "Exported Narration in cue slot must analytically differ from original due to PocketTTS replacement (got diff: \(cueDiff))")

        // 9. Verify untouched Narration outside that Cue remains original
        let exportedUntouchedPCM = try await extractor.extractPCMBuffer(
            from: exportedAsset,
            trackID: narrationTrack.trackID,
            timeRange: untouchedTimeRange,
            targetSampleRate: 16000.0,
            targetChannels: 1
        )
        let untouchedDiff = computeMeanAbsoluteDifference(bufferA: originalUntouchedPCM, bufferB: exportedUntouchedPCM)
        #expect(untouchedDiff < 0.001, "Untouched narration interval outside cue must match original source audio (got diff: \(untouchedDiff))")

        // 10. Verify the Passthrough Track remains preserved
        let exportedPassthroughPCM = try await extractor.extractPCMBuffer(
            from: exportedAsset,
            trackID: passthroughTrack.trackID,
            targetSampleRate: 16000.0
        )
        #expect(exportedPassthroughPCM.frameLength > 0)
        let passCrossings = countZeroCrossings(in: exportedPassthroughPCM, startSec: 1.0, durationSec: 1.0)
        #expect(passCrossings >= 400 && passCrossings <= 480, "Exported passthrough track must preserve continuous 220Hz tone (got \(passCrossings) zero crossings)")
        let passDiff = computeMeanAbsoluteDifference(bufferA: exportedPassthroughPCM, bufferB: sourcePassthroughPCM)
        #expect(passDiff < 0.001, "Exported passthrough track samples must match source passthrough track (got diff: \(passDiff))")

        // 11. Verify video compressed-sample identity remains unchanged
        #expect(!exportResult.wasVideoReencoded, "Video bitstream must not be re-encoded")
        #expect(exportResult.videoSampleCount > 0, "Video sample buffers must be preserved")
        let sourceVideoTracks = try await sourceAsset.loadTracks(withMediaType: .video)
        let exportedVideoTracks = try await exportedAsset.loadTracks(withMediaType: .video)
        #expect(sourceVideoTracks.count == 1)
        #expect(exportedVideoTracks.count == 1)
        let sourceVideoFormat = try await sourceVideoTracks[0].load(.formatDescriptions)
        let exportedVideoFormat = try await exportedVideoTracks[0].load(.formatDescriptions)
        #expect(sourceVideoFormat.first?.mediaSubType == exportedVideoFormat.first?.mediaSubType, "Video codec sub-type must be identical")
    }
}
