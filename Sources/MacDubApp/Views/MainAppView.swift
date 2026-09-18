import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import CoreMedia
import MacDubCore

public struct MainAppView: View {
    @ObservedObject public var appViewModel: AppViewModel

    public init(appViewModel: AppViewModel) {
        self.appViewModel = appViewModel
    }

    private var selectedCue: Cue? {
        guard let id = appViewModel.selectedCueID else { return nil }
        return appViewModel.cues.first(where: { $0.id == id })
    }

    private var selectedCueIndex: Int? {
        guard let id = appViewModel.selectedCueID else { return nil }
        return appViewModel.cues.firstIndex(where: { $0.id == id })
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Native Liquid Glass Top Toolbar
            MacDubToolbar(
                sourceURL: appViewModel.sourceMediaURL,
                projectBundleURL: appViewModel.projectBundleURL,
                isProcessing: appViewModel.isProcessing,
                statusMessage: appViewModel.statusMessage,
                onOpenMedia: openMediaFile,
                onOpenProject: openProjectFile,
                onSaveProject: saveProjectFile,
                onExport: { appViewModel.prepareExport() },
                onOpenSettings: { appViewModel.showProviderSettings = true }
            )

            Divider()

            // Main Information Architecture:
            // SCRIPT DOCUMENT (Primary Left) | REFERENCE MONITOR + CUE INSPECTOR (Right)
            HSplitView {
                // Left Column: Script / Narration Document (Primary Workspace)
                ZStack {
                    if appViewModel.sourceMediaURL == nil {
                        EmptyProjectView(
                            onOpenMedia: openMediaFile,
                            onOpenProject: openProjectFile
                        )
                    } else if appViewModel.isProcessing && appViewModel.cues.isEmpty {
                        TranscribingStateView(statusMessage: appViewModel.statusMessage)
                    } else {
                        ScriptDocumentView(
                            cues: $appViewModel.cues,
                            selectedCueID: $appViewModel.selectedCueID,
                            currentTime: appViewModel.timelineViewModel.clock.currentTime,
                            editorViewModel: appViewModel.scriptEditorViewModel,
                            onSeek: { time in
                                appViewModel.timelineViewModel.seek(to: time)
                            },
                            onSynthesizeCue: { id in
                                Task {
                                    try? await appViewModel.synthesizeCue(id: id, providerType: appViewModel.selectedProviderType)
                                }
                            },
                            onForceFitCue: { id in
                                Task {
                                    try? await appViewModel.forceFitCue(id: id)
                                }
                            },
                            onDiscardCandidate: { id in
                                appViewModel.discardCandidateCue(id: id)
                            },
                            onRestoreOriginalCue: { id in
                                appViewModel.restoreOriginalCue(id: id)
                            },
                            onOpenMedia: openMediaFile
                        )
                    }
                }
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)

                // Right Column: Reference Monitor + Contextual Cue Inspector
                VStack(spacing: 0) {
                    // Video Reference Monitor (Smaller, Immutable Synchronization Reference)
                    ReferenceMonitorView(
                        player: appViewModel.player,
                        currentTime: appViewModel.timelineViewModel.clock.currentTime,
                        totalDuration: appViewModel.totalDuration,
                        isPlaying: appViewModel.timelineViewModel.clock.isPlaying,
                        onTogglePlayPause: {
                            appViewModel.timelineViewModel.clock.togglePlayPause()
                        },
                        onStepBackward: {
                            appViewModel.timelineViewModel.clock.stepBackward(by: 5)
                        },
                        onStepForward: {
                            appViewModel.timelineViewModel.clock.stepForward(by: 5)
                        }
                    )
                    .padding(12)

                    Divider()

                    // Cue Inspector (Voice Engine, Duration Fit, AI Actions, Synthesis)
                    CueInspectorView(
                        cue: selectedCue,
                        cueIndex: selectedCueIndex,
                        totalCues: appViewModel.cues.count,
                        selectedProvider: $appViewModel.selectedProviderType,
                        referenceVoice: appViewModel.referenceVoice,
                        isSynthesizing: appViewModel.scriptEditorViewModel.isSynthesizing,
                        isRewriting: appViewModel.scriptEditorViewModel.isRewriting,
                        onSynthesize: {
                            if let id = appViewModel.selectedCueID {
                                Task {
                                    try? await appViewModel.synthesizeCue(id: id, providerType: appViewModel.selectedProviderType)
                                }
                            }
                        },
                        onPreviewAudio: {
                            if let cue = selectedCue, let path = cue.audioWAVRelativePath {
                                let base = appViewModel.projectBundleURL ?? appViewModel.sessionWorkingDir
                                let fullURL = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
                                let previewPlayer = AVPlayer(url: fullURL)
                                previewPlayer.play()
                            }
                        },
                        onForceFit: {
                            if let id = appViewModel.selectedCueID {
                                Task {
                                    try? await appViewModel.forceFitCue(id: id)
                                }
                            }
                        },
                        onDiscardCandidate: {
                            if let id = appViewModel.selectedCueID {
                                appViewModel.discardCandidateCue(id: id)
                            }
                        },
                        onSplitCue: {
                            if let id = appViewModel.selectedCueID {
                                appViewModel.splitCue(id: id, at: appViewModel.timelineViewModel.clock.currentTime)
                            }
                        },
                        onRestoreOriginal: {
                            if let id = appViewModel.selectedCueID {
                                appViewModel.restoreOriginalCue(id: id)
                            }
                        },
                        onTriggerRewrite: { action, title in
                            if let text = selectedCue?.text {
                                appViewModel.scriptEditorViewModel.triggerRewrite(cueText: text, action: action, title: title)
                            }
                        },
                        onOpenSettings: {
                            appViewModel.showProviderSettings = true
                        }
                    )
                }
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 440)
                .background(.ultraThinMaterial)
            }

            Divider()

            // Bottom Full-Width Narration Timeline
            NarrationTimelineView(
                viewModel: appViewModel.timelineViewModel,
                sourceURL: appViewModel.sourceMediaURL,
                waveform: appViewModel.multiScaleWaveform,
                isSingleTrackAdvisory: appViewModel.isSingleTrackAdvisory
            )
        }
        .background(MacDubTheme.baseGraphite)
        .sheet(isPresented: $appViewModel.showTrackPicker) {
            TrackPickerView(
                audioTracks: appViewModel.detectedAudioTracks,
                designatedNarrationID: $appViewModel.designatedNarrationID,
                passthroughTrackIDs: $appViewModel.passthroughTrackIDs,
                onConfirm: {
                    appViewModel.confirmTrackPicker()
                }
            )
        }
        .sheet(isPresented: $appViewModel.showExportSheet) {
            if let exportVM = appViewModel.exportSheetViewModel {
                ExportSheetView(
                    viewModel: exportVM,
                    onDismiss: {
                        appViewModel.showExportSheet = false
                    }
                )
            }
        }
        .sheet(isPresented: $appViewModel.showProviderSettings) {
            ProviderSettingsView(appViewModel: appViewModel)
        }
        .alert("Error", isPresented: Binding<Bool>(
            get: { appViewModel.errorMessage != nil },
            set: { if !$0 { appViewModel.errorMessage = nil } }
        )) {
            Button("OK") {
                appViewModel.errorMessage = nil
            }
        } message: {
            Text(appViewModel.errorMessage ?? "")
        }
    }

    private func openMediaFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.quickTimeMovie, .mpeg4Movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Select Screen Recording"
        if panel.runModal() == .OK, let url = panel.url {
            appViewModel.importMedia(from: url)
        }
    }

    private func openProjectFile() {
        let panel = NSOpenPanel()
        if let uti = UTType(filenameExtension: "voicefix") {
            panel.allowedContentTypes = [uti]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.title = "Open MacDub Project Bundle"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try appViewModel.loadProject(from: url)
            } catch {
                appViewModel.errorMessage = "Failed to open project: \(error.localizedDescription)"
                appViewModel.statusMessage = "Project load failed"
            }
        }
    }

    private func saveProjectFile() {
        let panel = NSSavePanel()
        if let uti = UTType(filenameExtension: "voicefix") {
            panel.allowedContentTypes = [uti]
        }
        panel.nameFieldStringValue = "Recording.voicefix"
        panel.title = "Save MacDub Project Bundle"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try appViewModel.saveProject(to: url)
            } catch {
                appViewModel.errorMessage = "Failed to save project: \(error.localizedDescription)"
                appViewModel.statusMessage = "Project save failed"
            }
        }
    }
}
