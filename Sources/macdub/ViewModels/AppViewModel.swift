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

    // MARK: - Media Import & Audio Routing (ADR-0003)

    public func importMedia(from url: URL) {
        self.sourceMediaURL = url
        self.statusMessage = "Inspecting audio tracks..."
        self.isProcessing = true
        self.errorMessage = nil

        let newPlayer = AVPlayer(url: url)
        self.player = newPlayer
        self.timelineViewModel.updatePlayer(newPlayer)

        Task {
            do {
                let inspection = try await trackInspector.inspect(assetURL: url)
                let asset = AVURLAsset(url: url)
                let dur = try await asset.load(.duration)

                await MainActor.run {
                    self.totalDuration = dur
                    self.timelineViewModel.setCues([], totalDuration: dur)

                    switch inspection {
                    case .singleTrack(let track, _):
                        self.detectedAudioTracks = [track]
                        self.designatedNarrationID = track.id
                        self.passthroughTrackIDs = []
                        self.isSingleTrackAdvisory = true
                        self.showTrackPicker = false
                        self.startCueGeneration(sourceURL: url, totalDuration: dur)

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
                }

                // Extract Waveform
                let waveform = try? await waveformExtractor.extractWaveform(
                    from: asset,
                    trackID: CMPersistentTrackID(self.designatedNarrationID),
                    cacheDirectory: nil,
                    progress: nil
                )
                await MainActor.run {
                    self.multiScaleWaveform = waveform
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                    self.statusMessage = "Error"
                }
            }
        }
    }

    public func confirmTrackPicker() {
        showTrackPicker = false
        guard let url = sourceMediaURL else { return }
        startCueGeneration(sourceURL: url, totalDuration: totalDuration)
    }

    private func startCueGeneration(sourceURL: URL, totalDuration: CMTime) {
        isProcessing = true
        statusMessage = "Transcribing narration and detecting speech cues..."

        Task {
            do {
                let result = try await cueGenerator.generateCues(from: sourceURL, totalDuration: totalDuration)
                await MainActor.run {
                    self.cues = result.cues
                    self.roomToneBuffer = result.roomToneBuffer
                    self.timelineViewModel.setCues(result.cues, totalDuration: totalDuration)
                    self.isProcessing = false
                    self.statusMessage = "Ready • \(result.cues.count) cues detected"
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                    self.statusMessage = "Transcription failed"
                }
            }
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

    public func synthesizeCue(id: UUID, providerType: SynthesisProviderType) async throws {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return }
        let cue = cues[index]

        let provider: VoiceSynthesisProvider
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

        let pcm = try await provider.synthesize(text: cue.text)
        let fitResult = try durationFitter.fit(
            synthesizedAudio: pcm,
            targetDuration: cue.duration,
            roomToneBuffer: roomToneBuffer,
            forceCompress: false
        )

        // Save WAV to temporary or project bundle cache
        let tempWAV = FileManager.default.temporaryDirectory
            .appendingPathComponent("dub_\(cue.id.uuidString).wav")
        if let buffer = fitResult.buffer {
            try writeBuffer(buffer, to: tempWAV)
        }

        switch fitResult {
        case .fitted:
            cues[index] = cue.withUpdatedAudio(
                audioWAVRelativePath: tempWAV.path,
                editState: .synthesized,
                overflowDelta: nil
            )
        case .overflow(let delta, _, _):
            cues[index] = cue.withUpdatedAudio(
                audioWAVRelativePath: tempWAV.path,
                editState: .overflowGated,
                overflowDelta: delta
            )
        }

        timelineViewModel.setCues(cues, totalDuration: totalDuration)
    }

    public func forceFitCue(id: UUID) async throws {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return }
        let cue = cues[index]

        // Synthesize with forced compression
        let provider = PocketTTSProvider()
        let pcm = try await provider.synthesize(text: cue.text)
        let fitResult = try durationFitter.fit(
            synthesizedAudio: pcm,
            targetDuration: cue.duration,
            roomToneBuffer: roomToneBuffer,
            forceCompress: true
        )

        let tempWAV = FileManager.default.temporaryDirectory
            .appendingPathComponent("dub_\(cue.id.uuidString).wav")
        if let buffer = fitResult.buffer {
            try writeBuffer(buffer, to: tempWAV)
        }

        cues[index] = cue.withUpdatedAudio(
            audioWAVRelativePath: tempWAV.path,
            editState: .forceFitted,
            overflowDelta: nil
        )

        timelineViewModel.setCues(cues, totalDuration: totalDuration)
    }

    // MARK: - Export (ADR-0008)

    public func prepareExport() {
        self.exportSheetViewModel = ExportSheetViewModel(
            sourceURL: sourceMediaURL,
            narrationTrackID: designatedNarrationID,
            passthroughTrackIDs: Array(passthroughTrackIDs),
            cues: cues,
            bundleRootURL: projectBundleURL
        )
        self.showExportSheet = true
    }

    // MARK: - Project Bundle Persistence (ADR-0004)

    public func saveProject(to url: URL) throws {
        guard let sourceURL = sourceMediaURL else { return }
        let metadata = ProjectMetadata(
            name: url.deletingPathExtension().lastPathComponent,
            sourceStorageMode: .cloned(relativePath: sourceURL.lastPathComponent),
            designatedNarrationTrackID: designatedNarrationID,
            passthroughTrackIDs: Array(passthroughTrackIDs),
            totalDuration: totalDuration,
            cues: cues
        )
        _ = try ProjectBundle.create(at: url, metadata: metadata)
        self.projectBundleURL = url
        self.statusMessage = "Project saved to \(url.lastPathComponent)"
    }

    private func writeBuffer(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        let file = try AVAudioFile(
            forWriting: url,
            settings: buffer.format.settings,
            commonFormat: buffer.format.commonFormat,
            interleaved: buffer.format.isInterleaved
        )
        try file.write(from: buffer)
    }
}
