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

    private var videoAspectRatio: CGFloat {
        guard let size = appViewModel.videoNaturalSize, size.height > 0 else {
            return 16.0 / 9.0
        }
        return size.width / size.height
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Main Information Architecture:
            // SCRIPT DOCUMENT (Primary Left) | REFERENCE MONITOR + CUE INSPECTOR (Right)
            HSplitView {
                // Left Column: Script / Narration Document (Primary Workspace)
                ZStack {
                    if appViewModel.sourceMediaURL == nil && appViewModel.projectBundleURL == nil {
                        EmptyProjectView(
                            onOpenMedia: openMediaFile,
                            onOpenProject: openProjectFile
                        )
                    } else {
                        ScriptDocumentView(
                            cues: $appViewModel.cues,
                            selectedCueID: $appViewModel.selectedCueID,
                            currentTime: appViewModel.timelineViewModel.clock.currentTime,
                            editorViewModel: appViewModel.scriptEditorViewModel,
                            isMediaLoaded: appViewModel.sourceMediaURL != nil || appViewModel.projectBundleURL != nil,
                            isTranscribing: appViewModel.isProcessing,
                            transcriptionStatus: appViewModel.statusMessage,
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
                            onOpenMedia: openMediaFile,
                            onTranscribeRecording: {
                                appViewModel.transcribeRecording()
                            }
                        )
                    }
                }
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)

                // Right Column: Reference Monitor + Contextual Cue Inspector (collapsible for narrow screens)
                if appViewModel.isInspectorVisible {
                    VStack(spacing: 0) {
                        // Video Reference Monitor (Smaller, Immutable Synchronization Reference)
                        ReferenceMonitorView(
                            player: appViewModel.player,
                            currentTime: appViewModel.timelineViewModel.clock.currentTime,
                            totalDuration: appViewModel.totalDuration,
                            isPlaying: appViewModel.timelineViewModel.clock.isPlaying,
                            videoAspectRatio: videoAspectRatio,
                            isExpandedPopoverPresented: $appViewModel.isExpandedVideoPopoverPresented,
                            onTogglePlayPause: {
                                appViewModel.timelineViewModel.clock.togglePlayPause()
                            },
                            onStepBackward: {
                                appViewModel.timelineViewModel.clock.seekBackward(by: 5.0)
                            },
                            onStepForward: {
                                appViewModel.timelineViewModel.clock.seekForward(by: 5.0)
                            }
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

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
                                if let cue = selectedCue {
                                    appViewModel.previewCueAudio(for: cue)
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
                            },
                            onImportReferenceVoice: {
                                importReferenceVoiceFile()
                            }
                        )
                    }
                    .frame(minWidth: 320, idealWidth: 360, maxWidth: 440)
                }
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
        .toolbar {
            MacDubToolbarContent(
                sourceURL: appViewModel.sourceMediaURL,
                projectBundleURL: appViewModel.projectBundleURL,
                isProcessing: appViewModel.isProcessing,
                statusMessage: appViewModel.statusMessage,
                hasUnsavedChanges: appViewModel.hasUnsavedChanges,
                selectedProvider: appViewModel.selectedProviderType,
                isInspectorVisible: appViewModel.isInspectorVisible,
                onOpenMedia: openMediaFile,
                onOpenProject: openProjectFile,
                onSaveProject: saveProjectFile,
                onExport: { appViewModel.prepareExport() },
                onOpenSettings: { appViewModel.showProviderSettings = true },
                onToggleInspector: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appViewModel.isInspectorVisible.toggle()
                    }
                }
            )
        }
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

    private var projectTitle: String {
        if let bundle = appViewModel.projectBundleURL {
            return bundle.deletingPathExtension().lastPathComponent
        }
        if let source = appViewModel.sourceMediaURL {
            return source.lastPathComponent
        }
        return "Untitled Project"
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

    private func importReferenceVoiceFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .quickTimeMovie, .wav, .mp3, .mpeg4Audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Import Reference Voice Audio"
        panel.message = "Select a clean audio recording (WAV, MP3, M4A, or MOV) of your voice."
        if panel.runModal() == .OK, let url = panel.url {
            let name = url.deletingPathExtension().lastPathComponent
            do {
                try appViewModel.setReferenceVoice(name: name, audioURL: url)
            } catch {
                appViewModel.errorMessage = "Failed to import reference voice: \(error.localizedDescription)"
            }
        }
    }
}
