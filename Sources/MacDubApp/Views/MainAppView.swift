import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CoreMedia
import MacDubCore

public struct MainAppView: View {
    @ObservedObject public var appViewModel: AppViewModel

    public init(appViewModel: AppViewModel) {
        self.appViewModel = appViewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top App Toolbar
            topToolbarView

            Divider()

            // Main Content Area: Split View
            HSplitView {
                // Left Column: Video Player + Timeline
                VStack(spacing: 0) {
                    // Video Player Area
                    ZStack {
                        Color.black

                        if let player = appViewModel.player {
                            VideoPlayerView(player: player)
                        } else {
                            emptyMediaPlaceholder
                        }
                    }
                    .frame(minHeight: 240, maxHeight: .infinity)

                    Divider()

                    // Fixed-Slot Sync Invariant Timeline
                    TimelineView(
                        viewModel: appViewModel.timelineViewModel,
                        sourceURL: appViewModel.sourceMediaURL,
                        waveform: appViewModel.multiScaleWaveform
                    )
                }
                .frame(minWidth: 500, maxWidth: .infinity)

                // Right Column: Script Editor Sidebar
                ScriptEditorSidebarView(
                    editorViewModel: appViewModel.scriptEditorViewModel,
                    cues: $appViewModel.cues,
                    selectedCueID: $appViewModel.selectedCueID,
                    currentTime: appViewModel.timelineViewModel.clock.currentTime,
                    onSeek: { time in
                        appViewModel.timelineViewModel.seek(to: time)
                    },
                    onSplitCue: { id, time in
                        appViewModel.splitCue(id: id, at: time)
                    },
                    onSynthesizeCue: { id, provider in
                        try await appViewModel.synthesizeCue(id: id, providerType: provider)
                    },
                    onForceFitCue: { id in
                        try await appViewModel.forceFitCue(id: id)
                    }
                )
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 500)
            }
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
            ProviderSettingsView()
        }
    }

    // MARK: - Toolbar
    private var topToolbarView: some View {
        HStack(spacing: 12) {
            // App Branding
            HStack(spacing: 6) {
                Image(systemName: "waveform.badge.mic")
                    .font(.title3)
                    .foregroundStyle(.blue)
                Text("macdub")
                    .font(.headline.bold())
            }

            Divider()
                .frame(height: 18)

            // Open Media
            Button(action: openMediaFile) {
                Label("Open Media...", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            // Open Project
            Button(action: openProjectFile) {
                Label("Open Project...", systemImage: "doc.badge.gearshape")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            // Save Project
            Button(action: saveProjectFile) {
                Label("Save Project", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(appViewModel.sourceMediaURL == nil)

            // Single Track Advisory (ADR-0003)
            if appViewModel.isSingleTrackAdvisory {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.yellow)
                    Text("Single Audio Track: Replacing narration may replace embedded system audio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.yellow.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Spacer()

            // Status indicator
            if appViewModel.isProcessing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(appViewModel.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(appViewModel.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Export Button (ADR-0008)
            Button(action: {
                appViewModel.prepareExport()
            }) {
                Label("Export Video...", systemImage: "arrow.up.forward.square.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(appViewModel.sourceMediaURL == nil)

            Divider()
                .frame(height: 18)

            // Provider & Keychain Settings
            Button(action: {
                appViewModel.showProviderSettings = true
            }) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Provider & Keychain Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Empty State Placeholder
    private var emptyMediaPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("No Screen Recording Loaded")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("Open a .mov or .mp4 recording to transcribe and edit speech")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button(action: openMediaFile) {
                Label("Select Video File...", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(32)
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
            try? appViewModel.loadProject(from: url)
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
            try? appViewModel.saveProject(to: url)
        }
    }
}
