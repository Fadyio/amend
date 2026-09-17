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

    // Waveform & Visuals
    @Published public var multiScaleWaveform: MultiScaleWaveform?
    @Published public var totalDuration: CMTime = .zero

    // Modal & Sheet Presentation
    @Published public var showTrackPicker: Bool = false
    @Published public var showExportSheet: Bool = false
    @Published public var showProviderSettings: Bool = false
    @Published public var isProcessing: Bool = false
    @Published public var statusMessage: String = "Ready"
    @Published public var errorMessage: String?

    // Child ViewModels & Controllers
    @Published public var timelineViewModel: TimelineViewModel
    public let scriptEditorViewModel: ScriptEditorViewModel
    public var exportSheetViewModel: ExportSheetViewModel?

    // AVPlayer
    public private(set) var player: AVPlayer?

    // Services
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
        trackInspector: AudioTrackInspector = AudioTrackInspector(),
        cueGenerator: CueGenerating = CueGenerator(),
        cueSplitter: CueSplitter = CueSplitter(),
        durationFitter: DurationFitting = DurationFitter(),
        waveformExtractor: WaveformExtractor = WaveformExtractor()
    ) {
        let tVM = timelineViewModel ?? TimelineViewModel(clock: TimelineClock())
        self.timelineViewModel = tVM
        self.scriptEditorViewModel = scriptEditorViewModel ?? ScriptEditorViewModel()
        self.trackInspector = trackInspector
        self.cueGenerator = cueGenerator
        self.cueSplitter = cueSplitter
        self.durationFitter = durationFitter
        self.waveformExtractor = waveformExtractor

        let workingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macdub_session_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workingDir.appendingPathComponent("audio/cues"), withIntermediateDirectories: true)
        self.sessionWorkingDir = workingDir

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
            try? await importMediaAsync(from: url)
        }
    }

    public func importMediaAsync(from url: URL) async throws {
        self.sourceMediaURL = url
        self.statusMessage = "Inspecting audio tracks..."
        self.isProcessing = true
        self.errorMessage = nil

        let newPlayer = AVPlayer(url: url)
        self.player = newPlayer
        self.timelineViewModel.updatePlayer(newPlayer)

        do {
            let inspection = try await trackInspector.inspect(assetURL: url)
            let asset = AVURLAsset(url: url)
            let dur = try await asset.load(.duration)

            // Inspect nominal frame rate (Phase 14)
            if let videoTrack = try await asset.loadTracks(withMediaType: .video).first {
                let fps = try await videoTrack.load(.nominalFrameRate)
                if fps > 0 {
                    let matchingRate = TimecodeFrameRate.closest(to: Double(fps))
                    self.timelineViewModel.rulerFormatter = SMPTERulerFormatter(frameRate: matchingRate)
                }
            }

            self.totalDuration = dur
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
            try? await confirmTrackPickerAsync()
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

    // MARK: - Cue Editing & Splitting (ADR-0001, ADR-0006)

    public func splitCue(id: UUID, at time: CMTime) {
        do {
            let (newCues, cueA, _) = try cueSplitter.splitCue(in: cues, targetCueID: id, at: time)
            self.cues = newCues
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
            switch providerType {
            case .pocketTTS:
                provider = PocketTTSProvider()
            case .elevenLabs:
                provider = ElevenLabsProvider()
            case .resemble:
                provider = ResembleProvider()
            case .geminiTTS:
                provider = GeminiTTSProvider()
            }
        }

        let pcm = try await provider.synthesize(text: cue.text)
        let fitResult = try durationFitter.fit(
            synthesizedAudio: pcm,
            targetDuration: cue.duration,
            roomToneBuffer: roomToneBuffer,
            forceCompress: false
        )

        // Save WAV into audio/cues/ directory (Phase 10)
        let relativePath = "audio/cues/cue_\(cue.id.uuidString).wav"
        let baseDir = projectBundleURL ?? sessionWorkingDir
        let targetWAV = baseDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: targetWAV.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let buffer = fitResult.buffer {
            try writeBuffer(buffer, to: targetWAV)
        }

        switch fitResult {
        case .fitted:
            cues[index] = cue.withUpdatedAudio(
                audioWAVRelativePath: relativePath,
                editState: .synthesized,
                overflowDelta: nil
            )
        case .overflow(let delta, _, _):
            cues[index] = cue.withUpdatedAudio(
                audioWAVRelativePath: relativePath,
                editState: .overflowGated,
                overflowDelta: delta
            )
        }

        timelineViewModel.setCues(cues, totalDuration: totalDuration)
        refreshPreviewPlayback()
    }

    public func forceFitCue(id: UUID) async throws {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return }
        let cue = cues[index]

        let provider = PocketTTSProvider()
        let pcm = try await provider.synthesize(text: cue.text)
        let fitResult = try durationFitter.fit(
            synthesizedAudio: pcm,
            targetDuration: cue.duration,
            roomToneBuffer: roomToneBuffer,
            forceCompress: true
        )

        let relativePath = "audio/cues/cue_\(cue.id.uuidString).wav"
        let baseDir = projectBundleURL ?? sessionWorkingDir
        let targetWAV = baseDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: targetWAV.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let buffer = fitResult.buffer {
            try writeBuffer(buffer, to: targetWAV)
        }

        cues[index] = cue.withUpdatedAudio(
            audioWAVRelativePath: relativePath,
            editState: .forceFitted,
            overflowDelta: nil
        )

        timelineViewModel.setCues(cues, totalDuration: totalDuration)
        refreshPreviewPlayback()
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
        self.player?.replaceCurrentItem(with: AVPlayerItem(asset: comp))
        return comp
    }

    private func refreshPreviewPlayback() {
        Task {
            try? await buildPreviewComposition()
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

        // Persist updated metadata with cues
        var updatedMetadata = bundle.metadata
        updatedMetadata.cues = cues
        updatedMetadata.designatedNarrationTrackID = designatedNarrationID
        updatedMetadata.passthroughTrackIDs = Array(passthroughTrackIDs)
        let updatedBundle = ProjectBundle(rootURL: bundleURL, metadata: updatedMetadata)
        try ProjectBundleSerializer.save(bundle: updatedBundle)

        self.projectBundleURL = bundleURL
        self.statusMessage = "Project saved to \(bundleURL.lastPathComponent)"
    }

    public func loadProject(from url: URL) throws {
        let bundle = try ProjectBundleSerializer.load(from: url)
        let resolvedMediaURL = try ProjectBundleSerializer.resolveSourceMediaURL(for: bundle)

        self.sourceMediaURL = resolvedMediaURL
        self.projectBundleURL = bundle.rootURL
        self.designatedNarrationID = bundle.metadata.designatedNarrationTrackID
        self.passthroughTrackIDs = Set(bundle.metadata.passthroughTrackIDs)
        self.isSingleTrackAdvisory = bundle.metadata.isSingleTrackAdvisory
        self.totalDuration = bundle.metadata.totalDuration
        self.cues = bundle.metadata.cues
        self.timelineViewModel.setCues(bundle.metadata.cues, totalDuration: bundle.metadata.totalDuration)

        let newPlayer = AVPlayer(url: resolvedMediaURL)
        self.player = newPlayer
        self.timelineViewModel.updatePlayer(newPlayer)
        self.statusMessage = "Project loaded: \(bundle.metadata.name)"

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
