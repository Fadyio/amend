import Foundation
import CoreMedia
import Combine
import AVFoundation
import AppKit
import MacDubCore

@MainActor
public final class AppViewModel: ObservableObject {
    // Current Project & Media State
    @Published public var projectBundleURL: URL?
    @Published public var sourceMediaURL: URL?
    @Published public var cues: [Cue] = []
    @Published public var selectedCueID: UUID?
    @Published public var designatedNarrationID: Int = 1
    @Published public var passthroughTrackIDs: Set<Int> = []
    @Published public var detectedAudioTracks: [AudioTrackInfo] = []
    @Published public var isSingleTrackAdvisory: Bool = false
    @Published public var referenceVoice: ReferenceVoice?
    @Published public var selectedProviderType: SynthesisProviderType = .pocketTTS

    // Waveform & Visuals
    @Published public var multiScaleWaveform: MultiScaleWaveform?
    @Published public var totalDuration: CMTime = .zero

    // Modal & Sheet Presentation
    @Published public var showTrackPicker: Bool = false
    @Published public var showExportSheet: Bool = false
    @Published public var showProviderSettings: Bool = false
    @Published public var isInspectorVisible: Bool = true
    @Published public var isExpandedVideoPopoverPresented: Bool = false
    @Published public var isProcessing: Bool = false
    @Published public var statusMessage: String = "Ready"
    @Published public var errorMessage: String?
    @Published public var hasUnsavedChanges: Bool = false
    @Published public var videoNaturalSize: CGSize?

    // Child ViewModels & Controllers
    @Published public var timelineViewModel: TimelineViewModel
    public let scriptEditorViewModel: ScriptEditorViewModel
    public var exportSheetViewModel: ExportSheetViewModel?

    // AVPlayer
    @Published public private(set) var player: AVPlayer?
    @Published public private(set) var cuePreviewPlayer: AVPlayer?

    // Services
    public let providerRegistry: SynthesisProviderRegistry
    private let trackInspector: AudioTrackInspector
    private let cueGenerator: CueGenerating
    private let cueSplitter: CueSplitter
    private let durationFitter: DurationFitting
    private let waveformExtractor: WaveformExtractor
    private var roomToneBuffer: AVAudioPCMBuffer?
    private var cancellables = Set<AnyCancellable>()

    // Managed working directory for unsaved projects (Phase 10)
    public let sessionWorkingDir: URL

    public init(
        timelineViewModel: TimelineViewModel? = nil,
        scriptEditorViewModel: ScriptEditorViewModel? = nil,
        providerRegistry: SynthesisProviderRegistry = SynthesisProviderRegistry(),
        trackInspector: AudioTrackInspector = AudioTrackInspector(),
        cueGenerator: CueGenerating = CueGenerator(),
        cueSplitter: CueSplitter = CueSplitter(),
        durationFitter: DurationFitting = DurationFitter(),
        waveformExtractor: WaveformExtractor = WaveformExtractor()
    ) {
        let tVM = timelineViewModel ?? TimelineViewModel(clock: TimelineClock())
        self.timelineViewModel = tVM
        let seVM = scriptEditorViewModel ?? ScriptEditorViewModel()
        self.scriptEditorViewModel = seVM
        self.providerRegistry = providerRegistry
        self.trackInspector = trackInspector
        self.cueGenerator = cueGenerator
        self.cueSplitter = cueSplitter
        self.durationFitter = durationFitter
        self.waveformExtractor = waveformExtractor

        let workingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macdub_session_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workingDir.appendingPathComponent("audio/cues"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: workingDir.appendingPathComponent("voice"), withIntermediateDirectories: true)
        self.sessionWorkingDir = workingDir

        // Wire ScriptEditorViewModel provider proxy to single source of truth in AppViewModel
        seVM.bindProvider(
            get: { [weak self] in self?.selectedProviderType ?? .pocketTTS },
            set: { [weak self] in self?.selectedProviderType = $0 }
        )

        // Forward cue selection from timeline to AppViewModel
        tVM.$selectedCueID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                if self?.selectedCueID != id {
                    self?.selectedCueID = id
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Media Import & Audio Routing (ADR-0003, Phase 14)

    public func importMedia(from url: URL) {
        Task {
            do {
                try await importMediaAsync(from: url)
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = "Import failed: \(error.localizedDescription)"
                    self.isProcessing = false
                }
            }
        }
    }

    public func importMediaAsync(from url: URL) async throws {
        self.sourceMediaURL = url
        self.statusMessage = "Inspecting audio tracks..."
        self.isProcessing = true
        self.errorMessage = nil

        // Pause and cleanly detach any existing player
        self.player?.pause()
        self.timelineViewModel.clock.detachPlayer()

        let newPlayer = AVPlayer(url: url)
        self.player = newPlayer
        self.timelineViewModel.updatePlayer(newPlayer)

        do {
            let inspection = try await trackInspector.inspect(assetURL: url)
            let asset = AVURLAsset(url: url)
            let dur = try await asset.load(.duration)

            // Inspect video track for frame rate and presentation aspect ratio
            if let videoTrack = try await asset.loadTracks(withMediaType: .video).first {
                let fps = try await videoTrack.load(.nominalFrameRate)
                if fps > 0 {
                    let matchingRate = TimecodeFrameRate.closest(to: Double(fps))
                    self.timelineViewModel.rulerFormatter = SMPTERulerFormatter(frameRate: matchingRate)
                    self.timelineViewModel.clock.frameRate = Double(fps)
                }
                let rawSize = try await videoTrack.load(.naturalSize)
                let transform = try await videoTrack.load(.preferredTransform)
                let transformedRect = CGRect(origin: .zero, size: rawSize).applying(transform)
                let presentationSize = CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))
                self.videoNaturalSize = (presentationSize.width > 0 && presentationSize.height > 0) ? presentationSize : rawSize
            } else {
                self.videoNaturalSize = nil
            }

            self.totalDuration = dur
            self.hasUnsavedChanges = false
            self.timelineViewModel.setCues([], totalDuration: dur)

            switch inspection {
            case .singleTrack(let track, _):
                self.detectedAudioTracks = [track]
                self.designatedNarrationID = track.id
                self.passthroughTrackIDs = []
                self.isSingleTrackAdvisory = true
                self.showTrackPicker = false
                try await generateCuesAsync(sourceURL: url, totalDuration: dur, narrationTrackID: CMPersistentTrackID(track.id))

            case .multiTrack(let tracks, let defaultMapping):
                self.detectedAudioTracks = tracks
                self.designatedNarrationID = defaultMapping.designatedNarrationTrackID
                self.passthroughTrackIDs = Set(defaultMapping.passthroughTrackIDs)
                self.isSingleTrackAdvisory = false
                self.showTrackPicker = true
                self.isProcessing = false
                self.statusMessage = "Awaiting track configuration..."

            case .noAudioTracks:
                self.errorMessage = "No audio tracks detected in media file."
                self.isProcessing = false
                self.statusMessage = "Error"
            }

            // Extract Waveform for designated narration track
            let waveform = try? await waveformExtractor.extractWaveform(
                from: asset,
                trackID: CMPersistentTrackID(self.designatedNarrationID),
                cacheDirectory: nil,
                progress: nil
            )
            self.multiScaleWaveform = waveform
        } catch {
            self.errorMessage = error.localizedDescription
            self.isProcessing = false
            self.statusMessage = "Error"
            throw error
        }
    }

    public func confirmTrackPicker() {
        Task {
            do {
                try await confirmTrackPickerAsync()
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = "Track configuration failed: \(error.localizedDescription)"
                    self.isProcessing = false
                }
            }
        }
    }

    public func confirmTrackPickerAsync() async throws {
        showTrackPicker = false
        guard let url = sourceMediaURL else { return }
        try await generateCuesAsync(sourceURL: url, totalDuration: totalDuration, narrationTrackID: CMPersistentTrackID(designatedNarrationID))

        let asset = AVURLAsset(url: url)
        let waveform = try? await waveformExtractor.extractWaveform(
            from: asset,
            trackID: CMPersistentTrackID(self.designatedNarrationID),
            cacheDirectory: nil,
            progress: nil
        )
        self.multiScaleWaveform = waveform
    }

    public func generateCuesAsync(sourceURL: URL, totalDuration: CMTime, narrationTrackID: CMPersistentTrackID? = nil) async throws {
        isProcessing = true
        statusMessage = "Transcribing narration and detecting speech cues..."

        do {
            let targetTrackID = narrationTrackID ?? CMPersistentTrackID(designatedNarrationID)
            let result = try await cueGenerator.generateCues(from: sourceURL, totalDuration: totalDuration, narrationTrackID: targetTrackID)
            self.cues = result.cues
            self.roomToneBuffer = result.roomToneBuffer
            self.timelineViewModel.setCues(result.cues, totalDuration: totalDuration)
            self.isProcessing = false
            self.statusMessage = "Ready • \(result.cues.count) cues detected"
        } catch {
            self.errorMessage = error.localizedDescription
            self.isProcessing = false
            self.statusMessage = "Transcription failed"
            throw error
        }
    }

    // MARK: - Reference Voice Management (Blocker 1 & 5)

    public func setReferenceVoice(name: String, audioURL: URL) throws {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw SynthesisError.invalidReferenceAudio
        }
        let baseDir = projectBundleURL ?? sessionWorkingDir
        let voiceDir = baseDir.appendingPathComponent("voice")
        try FileManager.default.createDirectory(at: voiceDir, withIntermediateDirectories: true)

        let relativePath = "voice/reference_voice.wav"
        let targetVoiceURL = baseDir.appendingPathComponent(relativePath)

        if FileManager.default.fileExists(atPath: targetVoiceURL.path) {
            try? FileManager.default.removeItem(at: targetVoiceURL)
        }
        try AudioBufferUtils.canonicalizeToWAV(sourceURL: audioURL, destinationURL: targetVoiceURL)
        providerRegistry.pocketTTS.invalidateVoiceCache()

        self.referenceVoice = ReferenceVoice(
            name: name,
            audioRelativePath: relativePath,
            pocketTTSStatus: .configured
        )
        self.hasUnsavedChanges = true
        self.statusMessage = "Configured Reference Voice: \(name)"
    }

    public func cloneElevenLabsVoice(name: String) async throws -> String {
        guard let refVoice = referenceVoice else {
            throw SynthesisError.invalidReferenceAudio
        }
        let baseDir = projectBundleURL ?? sessionWorkingDir
        let fullVoiceURL = refVoice.audioRelativePath.hasPrefix("/")
            ? URL(fileURLWithPath: refVoice.audioRelativePath)
            : baseDir.appendingPathComponent(refVoice.audioRelativePath)

        let provider = providerRegistry.elevenLabs
        let voiceID = try await provider.cloneVoice(name: name, audioURL: fullVoiceURL)
        self.referenceVoice?.elevenLabsVoiceID = voiceID
        self.statusMessage = "ElevenLabs voice cloned successfully"
        return voiceID
    }

    public func setResembleVoiceUUID(_ uuid: String) {
        if referenceVoice != nil {
            referenceVoice?.resembleVoiceUUID = uuid
        } else {
            referenceVoice = ReferenceVoice(
                name: "Resemble Voice",
                audioRelativePath: "",
                pocketTTSStatus: .unconfigured,
                resembleVoiceUUID: uuid
            )
        }
        self.statusMessage = "Configured Resemble voice UUID"
    }

    public func setElevenLabsVoiceID(_ id: String) {
        if referenceVoice != nil {
            referenceVoice?.elevenLabsVoiceID = id
        } else {
            referenceVoice = ReferenceVoice(
                name: "ElevenLabs Voice",
                audioRelativePath: "",
                pocketTTSStatus: .unconfigured,
                elevenLabsVoiceID: id
            )
        }
        self.statusMessage = "Configured ElevenLabs voice ID"
    }

    // MARK: - Cue Editing & Splitting (ADR-0001, ADR-0006)

    public func splitCue(id: UUID, at time: CMTime) {
        do {
            let (newCues, cueA, _) = try cueSplitter.splitCue(in: cues, targetCueID: id, at: time)
            self.cues = newCues
            self.hasUnsavedChanges = true
            self.timelineViewModel.setCues(newCues, totalDuration: totalDuration)
            self.selectedCueID = cueA.id
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    public func synthesizeCue(
        id: UUID,
        providerType: SynthesisProviderType = .pocketTTS,
        customProvider: VoiceSynthesisProvider? = nil
    ) async throws {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return }
        let cue = cues[index]

        let provider: VoiceSynthesisProvider
        if let custom = customProvider {
            provider = custom
        } else {
            provider = providerRegistry.provider(for: providerType)
        }

        let baseDir = projectBundleURL ?? sessionWorkingDir
        var refAudioURL: URL? = nil
        var voiceID: String? = nil

        switch providerType {
        case .pocketTTS:
            if let refVoice = referenceVoice {
                let path = refVoice.audioRelativePath
                let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : baseDir.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: url.path) {
                    refAudioURL = url
                }
            }
            if customProvider == nil && refAudioURL == nil {
                throw SynthesisError.invalidReferenceAudio
            }

        case .elevenLabs:
            if let vid = referenceVoice?.elevenLabsVoiceID, !vid.isEmpty {
                voiceID = vid
            } else if let refVoice = referenceVoice {
                let path = refVoice.audioRelativePath
                let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : baseDir.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: url.path) {
                    refAudioURL = url
                }
            }
            if customProvider == nil && voiceID == nil && refAudioURL == nil {
                throw SynthesisError.synthesisFailed("ElevenLabs requires a cloned voice ID or reference voice.")
            }

        case .resemble:
            if let vid = referenceVoice?.resembleVoiceUUID, !vid.isEmpty {
                voiceID = vid
            }
            if customProvider == nil && voiceID == nil {
                throw SynthesisError.synthesisFailed("Resemble requires a voice_uuid configured in Reference Voice or Provider Settings.")
            }

        case .geminiTTS:
            voiceID = "Puck"
            refAudioURL = nil
        }

        if providerType == .pocketTTS && referenceVoice != nil {
            referenceVoice?.pocketTTSStatus = .loading
        }

        let pcm: AVAudioPCMBuffer
        do {
            pcm = try await provider.synthesize(text: cue.text, voiceID: voiceID, referenceAudioURL: refAudioURL)
            if providerType == .pocketTTS && referenceVoice != nil {
                referenceVoice?.pocketTTSStatus = .ready
            }
        } catch {
            if providerType == .pocketTTS && referenceVoice != nil {
                referenceVoice?.pocketTTSStatus = .failed
            }
            throw error
        }

        // Extract original narration reference slice for loudness matching (Blocker 9)
        var refNarrationBuffer: AVAudioPCMBuffer? = nil
        if let mediaURL = sourceMediaURL {
            let asset = AVURLAsset(url: mediaURL)
            let extractor = AudioTrackExtractor()
            refNarrationBuffer = try? await extractor.extractPCMBuffer(
                from: asset,
                trackID: CMPersistentTrackID(designatedNarrationID),
                timeRange: cue.timeRange,
                targetSampleRate: pcm.format.sampleRate,
                targetChannels: pcm.format.channelCount
            )
        }

        let fitResult = try durationFitter.fit(
            synthesizedAudio: pcm,
            targetDuration: cue.duration,
            roomToneBuffer: roomToneBuffer,
            referenceAudioBuffer: refNarrationBuffer,
            forceCompress: false
        )

        switch fitResult {
        case .fitted(let fittedBuffer):
            let relativePath = "audio/cues/cue_\(cue.id.uuidString).wav"
            let targetWAV = baseDir.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: targetWAV.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeBuffer(fittedBuffer, to: targetWAV)

            let genDur = CMTime(seconds: Double(fittedBuffer.frameLength) / fittedBuffer.format.sampleRate, preferredTimescale: 600_000)

            cues[index] = cue.withUpdatedAudio(
                audioWAVRelativePath: relativePath,
                editState: .synthesized,
                overflowDelta: nil,
                generatedDuration: genDur
            )
            self.hasUnsavedChanges = true
            timelineViewModel.setCues(cues, totalDuration: totalDuration)
            refreshPreviewPlayback()
            statusMessage = "Fitted replacement audio for cue \(index + 1)"

        case .overflow(let delta, _, let uncompressedBuffer):
            // BLOCKER 7: Save uncompressed candidate WAV for inspection, but do NOT put in active audioWAVRelativePath or preview/export!
            let relativeCandidatePath = "audio/cues/candidate_\(cue.id.uuidString).wav"
            let targetCandidateWAV = baseDir.appendingPathComponent(relativeCandidatePath)
            try FileManager.default.createDirectory(at: targetCandidateWAV.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeBuffer(uncompressedBuffer, to: targetCandidateWAV)

            let uncompressedDur = CMTime(seconds: Double(uncompressedBuffer.frameLength) / uncompressedBuffer.format.sampleRate, preferredTimescale: 600_000)

            cues[index] = cue.withCandidateAudio(
                candidateAudioWAVRelativePath: relativeCandidatePath,
                overflowDelta: delta,
                generatedDuration: uncompressedDur
            )
            self.hasUnsavedChanges = true
            timelineViewModel.setCues(cues, totalDuration: totalDuration)
            refreshPreviewPlayback() // Candidate audio is strictly ignored by preview
            statusMessage = String(format: "Cue duration overflow (+%.2fs). Awaiting user resolution.", CMTimeGetSeconds(delta))
        }
    }

    public func forceFitCue(id: UUID) async throws {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return }
        let cue = cues[index]
        let baseDir = projectBundleURL ?? sessionWorkingDir

        let pcm: AVAudioPCMBuffer
        var candidateFileURLToDelete: URL? = nil
        if let candRel = cue.candidateAudioWAVRelativePath {
            let fullCandURL = candRel.hasPrefix("/") ? URL(fileURLWithPath: candRel) : baseDir.appendingPathComponent(candRel)
            if FileManager.default.fileExists(atPath: fullCandURL.path),
               let candData = try? Data(contentsOf: fullCandURL),
               let buf = try? AudioBufferUtils.pcmBuffer(fromAudioData: candData, fileExtension: "wav") {
                pcm = buf
                candidateFileURLToDelete = fullCandURL
            } else {
                throw SynthesisError.synthesisFailed("Candidate audio file missing for force fitting cue \(cue.id)")
            }
        } else {
            throw SynthesisError.synthesisFailed("No candidate audio available to force fit for cue \(cue.id)")
        }

        // Extract original narration reference slice for loudness matching (Blocker 9)
        var refNarrationBuffer: AVAudioPCMBuffer? = nil
        if let mediaURL = sourceMediaURL {
            let asset = AVURLAsset(url: mediaURL)
            let extractor = AudioTrackExtractor()
            refNarrationBuffer = try? await extractor.extractPCMBuffer(
                from: asset,
                trackID: CMPersistentTrackID(designatedNarrationID),
                timeRange: cue.timeRange,
                targetSampleRate: pcm.format.sampleRate,
                targetChannels: pcm.format.channelCount
            )
        }

        let fitResult = try durationFitter.fit(
            synthesizedAudio: pcm,
            targetDuration: cue.duration,
            roomToneBuffer: roomToneBuffer,
            referenceAudioBuffer: refNarrationBuffer,
            forceCompress: true
        )

        guard let buffer = fitResult.buffer else {
            throw SynthesisError.synthesisFailed("Failed to compress buffer")
        }

        let relativePath = "audio/cues/cue_\(cue.id.uuidString).wav"
        let targetWAV = baseDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: targetWAV.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeBuffer(buffer, to: targetWAV)

        // Clean up candidate audio file from disk
        if let candURL = candidateFileURLToDelete {
            try? FileManager.default.removeItem(at: candURL)
        }

        let genDur = CMTime(seconds: Double(buffer.frameLength) / buffer.format.sampleRate, preferredTimescale: 600_000)

        cues[index] = cue.withUpdatedAudio(
            audioWAVRelativePath: relativePath,
            editState: .forceFitted,
            overflowDelta: nil,
            generatedDuration: genDur
        )
        self.hasUnsavedChanges = true

        timelineViewModel.setCues(cues, totalDuration: totalDuration)
        refreshPreviewPlayback()
        statusMessage = "Force-fitted replacement audio for cue \(index + 1)"
    }

    public func discardCandidateCue(id: UUID) {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return }
        let cue = cues[index]
        let baseDir = projectBundleURL ?? sessionWorkingDir

        if let candRel = cue.candidateAudioWAVRelativePath {
            let fullCandURL = candRel.hasPrefix("/") ? URL(fileURLWithPath: candRel) : baseDir.appendingPathComponent(candRel)
            try? FileManager.default.removeItem(at: fullCandURL)
        }

        cues[index] = cue.withDiscardedCandidate()
        self.hasUnsavedChanges = true
        timelineViewModel.setCues(cues, totalDuration: totalDuration)
        refreshPreviewPlayback()
        statusMessage = "Discarded overflow candidate"
    }

    public func updateCueText(id: UUID, newText: String) {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return }
        cues[index] = cues[index].withUpdatedText(newText)
        self.hasUnsavedChanges = true
        timelineViewModel.setCues(cues, totalDuration: totalDuration)
    }

    public func restoreOriginalCue(id: UUID) {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return }
        let original = cues[index].originalText
        cues[index] = cues[index].withUpdatedText(original)
        self.hasUnsavedChanges = true
        timelineViewModel.setCues(cues, totalDuration: totalDuration)
    }

    public func previewCueAudio(for cue: Cue) {
        guard let path = cue.audioWAVRelativePath else { return }
        let base = projectBundleURL ?? sessionWorkingDir
        let fullURL = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: fullURL.path) else { return }

        let p = AVPlayer(url: fullURL)
        self.cuePreviewPlayer = p
        p.play()
    }

    // MARK: - Preview Composition Playback (Phase 12)

    @discardableResult
    public func buildPreviewComposition() async throws -> AVComposition {
        guard let sourceURL = sourceMediaURL else {
            throw NSError(domain: "AppViewModel", code: 404, userInfo: [NSLocalizedDescriptionKey: "No source media URL"])
        }
        let compGen = PreviewCompositionGenerator()
        let comp = try await compGen.generateComposition(
            sourceURL: sourceURL,
            designatedNarrationTrackID: CMPersistentTrackID(self.designatedNarrationID),
            passthroughTrackIDs: Array(self.passthroughTrackIDs).map { CMPersistentTrackID($0) },
            cues: self.cues,
            bundleRootURL: self.projectBundleURL ?? self.sessionWorkingDir
        )
        let wasPlaying = self.timelineViewModel.clock.isPlaying
        let currentTime = self.timelineViewModel.clock.currentTime
        let newItem = AVPlayerItem(asset: comp)
        if let player = self.player {
            player.replaceCurrentItem(with: newItem)
            if currentTime.isValid && !currentTime.isIndefinite && currentTime > .zero {
                await player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            if wasPlaying {
                self.timelineViewModel.clock.play()
            }
        } else {
            let newPlayer = AVPlayer(playerItem: newItem)
            self.player = newPlayer
            self.timelineViewModel.updatePlayer(newPlayer)
        }
        return comp
    }

    private func refreshPreviewPlayback() {
        Task {
            do {
                try await buildPreviewComposition()
            } catch {
                self.errorMessage = "Preview refresh error: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Export (ADR-0008)

    public func prepareExport() {
        self.exportSheetViewModel = ExportSheetViewModel(
            sourceURL: sourceMediaURL,
            narrationTrackID: designatedNarrationID,
            passthroughTrackIDs: Array(passthroughTrackIDs),
            cues: cues,
            bundleRootURL: projectBundleURL ?? sessionWorkingDir
        )
        self.showExportSheet = true
    }

    // MARK: - Project Bundle Persistence (ADR-0004, Phase 10 & 11)

    public func saveProject(to url: URL) throws {
        guard let sourceURL = sourceMediaURL else { return }
        var bundleURL = url
        if bundleURL.pathExtension != ProjectBundle.packageExtension {
            bundleURL = bundleURL.appendingPathExtension(ProjectBundle.packageExtension)
        }

        let bundle: ProjectBundle
        if FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("project.json").path) {
            bundle = try ProjectBundleSerializer.load(from: bundleURL)
        } else {
            bundle = try ProjectBundleSerializer.createBundle(
                at: bundleURL,
                sourceMediaURL: sourceURL,
                name: bundleURL.deletingPathExtension().lastPathComponent,
                designatedNarrationTrackID: designatedNarrationID,
                passthroughTrackIDs: Array(passthroughTrackIDs),
                isSingleTrackAdvisory: isSingleTrackAdvisory,
                totalDuration: totalDuration
            )
        }

        // Migrate generated cue WAVs from sessionWorkingDir to bundle audio/cues/
        let fm = FileManager.default
        let sessionCuesDir = sessionWorkingDir.appendingPathComponent("audio/cues")
        let bundleCuesDir = bundleURL.appendingPathComponent("audio/cues")
        try fm.createDirectory(at: bundleCuesDir, withIntermediateDirectories: true)

        if let cueFiles = try? fm.contentsOfDirectory(atPath: sessionCuesDir.path) {
            for file in cueFiles {
                let src = sessionCuesDir.appendingPathComponent(file)
                let dst = bundleCuesDir.appendingPathComponent(file)
                if fm.fileExists(atPath: dst.path) {
                    try? fm.removeItem(at: dst)
                }
                try? fm.copyItem(at: src, to: dst)
            }
        }

        // Migrate voice files from sessionWorkingDir to bundle voice/
        let sessionVoiceDir = sessionWorkingDir.appendingPathComponent("voice")
        let bundleVoiceDir = bundleURL.appendingPathComponent("voice")
        try fm.createDirectory(at: bundleVoiceDir, withIntermediateDirectories: true)

        if let voiceFiles = try? fm.contentsOfDirectory(atPath: sessionVoiceDir.path) {
            for file in voiceFiles {
                let src = sessionVoiceDir.appendingPathComponent(file)
                let dst = bundleVoiceDir.appendingPathComponent(file)
                if fm.fileExists(atPath: dst.path) {
                    try? fm.removeItem(at: dst)
                }
                try? fm.copyItem(at: src, to: dst)
            }
        }

        // Persist updated metadata with cues, referenceVoice, nominalFrameRate, activeProviderType
        var updatedMetadata = bundle.metadata
        updatedMetadata.cues = cues
        updatedMetadata.designatedNarrationTrackID = designatedNarrationID
        updatedMetadata.passthroughTrackIDs = Array(passthroughTrackIDs)
        updatedMetadata.referenceVoice = referenceVoice
        updatedMetadata.activeProviderType = selectedProviderType
        updatedMetadata.nominalFrameRate = timelineViewModel.clock.frameRate
        updatedMetadata.elevenLabsVoiceID = referenceVoice?.elevenLabsVoiceID
        updatedMetadata.resembleVoiceUUID = referenceVoice?.resembleVoiceUUID

        let updatedBundle = ProjectBundle(rootURL: bundleURL, metadata: updatedMetadata)
        try ProjectBundleSerializer.save(bundle: updatedBundle)

        self.projectBundleURL = bundleURL
        self.hasUnsavedChanges = false
        self.statusMessage = "Project saved to \(bundleURL.lastPathComponent)"
    }

    public func loadProject(from url: URL) throws {
        var bundleURL = url
        if bundleURL.pathExtension != ProjectBundle.packageExtension && !FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("project.json").path) {
            let withExt = bundleURL.appendingPathExtension(ProjectBundle.packageExtension)
            if FileManager.default.fileExists(atPath: withExt.appendingPathComponent("project.json").path) {
                bundleURL = withExt
            }
        }
        let bundle = try ProjectBundleSerializer.load(from: bundleURL)
        let resolvedMediaURL = try ProjectBundleSerializer.resolveSourceMediaURL(for: bundle)

        self.sourceMediaURL = resolvedMediaURL
        self.projectBundleURL = bundle.rootURL
        self.designatedNarrationID = bundle.metadata.designatedNarrationTrackID
        self.passthroughTrackIDs = Set(bundle.metadata.passthroughTrackIDs)
        self.isSingleTrackAdvisory = bundle.metadata.isSingleTrackAdvisory
        self.totalDuration = bundle.metadata.totalDuration
        self.cues = bundle.metadata.cues
        self.referenceVoice = bundle.metadata.referenceVoice
        self.hasUnsavedChanges = false
        if let prov = bundle.metadata.activeProviderType {
            self.selectedProviderType = prov
        }
        if let fps = bundle.metadata.nominalFrameRate, fps > 0 {
            self.timelineViewModel.clock.frameRate = fps
            let matchingRate = TimecodeFrameRate.closest(to: fps)
            self.timelineViewModel.rulerFormatter = SMPTERulerFormatter(frameRate: matchingRate)
        }
        self.timelineViewModel.setCues(bundle.metadata.cues, totalDuration: bundle.metadata.totalDuration)

        // Pause and cleanly detach any existing player
        self.player?.pause()
        self.timelineViewModel.clock.detachPlayer()

        let newPlayer = AVPlayer(url: resolvedMediaURL)
        self.player = newPlayer
        self.timelineViewModel.updatePlayer(newPlayer)
        self.statusMessage = "Project loaded: \(bundle.metadata.name)"

        Task {
            let asset = AVURLAsset(url: resolvedMediaURL)
            if let videoTrack = try? await asset.loadTracks(withMediaType: .video).first {
                let rawSize = (try? await videoTrack.load(.naturalSize)) ?? .zero
                let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
                let transformedRect = CGRect(origin: .zero, size: rawSize).applying(transform)
                let presentationSize = CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))
                await MainActor.run {
                    self.videoNaturalSize = (presentationSize.width > 0 && presentationSize.height > 0) ? presentationSize : rawSize
                }
            }
        }

        refreshPreviewPlayback()
    }

    private func writeBuffer(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: buffer.format.settings,
            commonFormat: buffer.format.commonFormat,
            interleaved: buffer.format.isInterleaved
        )
        try file.write(from: buffer)
    }
}
