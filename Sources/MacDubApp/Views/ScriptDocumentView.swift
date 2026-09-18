import SwiftUI
import CoreMedia
import MacDubCore

public struct ScriptDocumentView: View {
    @Binding public var cues: [Cue]
    @Binding public var selectedCueID: UUID?
    public let currentTime: CMTime
    @ObservedObject public var editorViewModel: ScriptEditorViewModel

    public let isMediaLoaded: Bool
    public let isTranscribing: Bool
    public let transcriptionStatus: String
    public let onSeek: (CMTime) -> Void
    public let onSynthesizeCue: (UUID) -> Void
    public let onForceFitCue: (UUID) -> Void
    public let onDiscardCandidate: (UUID) -> Void
    public let onRestoreOriginalCue: (UUID) -> Void
    public let onOpenMedia: () -> Void
    public let onTranscribeRecording: () -> Void

    public init(
        cues: Binding<[Cue]>,
        selectedCueID: Binding<UUID?>,
        currentTime: CMTime,
        editorViewModel: ScriptEditorViewModel,
        isMediaLoaded: Bool = true,
        isTranscribing: Bool = false,
        transcriptionStatus: String = "",
        onSeek: @escaping (CMTime) -> Void,
        onSynthesizeCue: @escaping (UUID) -> Void,
        onForceFitCue: @escaping (UUID) -> Void,
        onDiscardCandidate: @escaping (UUID) -> Void,
        onRestoreOriginalCue: @escaping (UUID) -> Void,
        onOpenMedia: @escaping () -> Void,
        onTranscribeRecording: @escaping () -> Void = {}
    ) {
        self._cues = cues
        self._selectedCueID = selectedCueID
        self.currentTime = currentTime
        self.editorViewModel = editorViewModel
        self.isMediaLoaded = isMediaLoaded
        self.isTranscribing = isTranscribing
        self.transcriptionStatus = transcriptionStatus
        self.onSeek = onSeek
        self.onSynthesizeCue = onSynthesizeCue
        self.onForceFitCue = onForceFitCue
        self.onDiscardCandidate = onDiscardCandidate
        self.onRestoreOriginalCue = onRestoreOriginalCue
        self.onOpenMedia = onOpenMedia
        self.onTranscribeRecording = onTranscribeRecording
    }

    private var selectedIndex: Int? {
        guard let id = selectedCueID else { return nil }
        return cues.firstIndex(where: { $0.id == id })
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Document Surface Header
            HStack(spacing: 10) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(MacDubTheme.accent)

                Text("Narration Script")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()

                if !cues.isEmpty {
                    Text("\(cues.count) paragraphs • \(formatDuration(totalSpeechDuration)) total speech")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)

            Divider()

            // Document Body
            if cues.isEmpty {
                emptyDocumentView
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(Array(cues.enumerated()), id: \.element.id) { index, cue in
                                ScriptCueRow(
                                    cue: cue,
                                    index: index,
                                    isSelected: selectedCueID == cue.id,
                                    isActive: cue.contains(time: currentTime),
                                    currentTime: currentTime,
                                    onSelect: {
                                        selectedCueID = cue.id
                                    },
                                    onSeek: { time in
                                        onSeek(time)
                                    },
                                    onUpdateText: { newText in
                                        updateCueText(at: index, newText: newText)
                                    },
                                    onTriggerRewrite: { action, title in
                                        editorViewModel.triggerRewrite(cueText: cue.text, action: action, title: title)
                                    },
                                    onRestoreOriginal: {
                                        onRestoreOriginalCue(cue.id)
                                    },
                                    onSynthesize: {
                                        onSynthesizeCue(cue.id)
                                    }
                                )
                                .id(cue.id)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: selectedCueID) { _, newID in
                        if let newID = newID {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(newID, anchor: .center)
                            }
                        }
                    }
                }
                .background(MacDubTheme.wellGraphite)
            }
        }
        .sheet(item: Binding<IdentifiableRewriteResult?>(
            get: { editorViewModel.activeRewriteResult.map { IdentifiableRewriteResult(result: $0) } },
            set: { editorViewModel.activeRewriteResult = $0?.result }
        )) { item in
            DiffPreviewView(
                result: item.result,
                actionTitle: editorViewModel.activeRewriteActionTitle,
                onApply: { updatedText in
                    if let index = selectedIndex {
                        cues[index] = cues[index].withUpdatedText(updatedText)
                    }
                    editorViewModel.activeRewriteResult = nil
                },
                onCancel: {
                    editorViewModel.activeRewriteResult = nil
                }
            )
        }
    }

    private var emptyDocumentView: some View {
        VStack(spacing: 16) {
            if isTranscribing {
                ProgressView()
                    .scaleEffect(1.3)
                    .controlSize(.regular)

                VStack(spacing: 6) {
                    Text("Analyzing narration…")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(transcriptionStatus.isEmpty ? "Transcribing locally with Parakeet" : transcriptionStatus)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if isMediaLoaded {
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(MacDubTheme.accent)

                VStack(spacing: 6) {
                    Text("Ready to transcribe")
                        .font(.title2.bold())
                        .foregroundStyle(.primary)

                    Text("Generate narration cues from this recording to start editing.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                Button(action: onTranscribeRecording) {
                    Label("Transcribe Recording", systemImage: "sparkles")
                        .frame(minWidth: 160)
                }
                .buttonStyle(GlassButtonStyle(isProminent: true))
                .controlSize(.large)
            } else {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 44))
                    .foregroundStyle(MacDubTheme.accent.opacity(0.8))

                VStack(spacing: 6) {
                    Text("MacDub")
                        .font(.title2.bold())
                        .foregroundStyle(.primary)

                    Text("Repair your hackathon narration\nwithout re-recording your demo.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                Button(action: onOpenMedia) {
                    Label("Open Recording...", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(GlassButtonStyle(isProminent: true))
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .background(MacDubTheme.wellGraphite)
    }

    private func updateCueText(at index: Int, newText: String) {
        guard index < cues.count else { return }
        cues[index] = cues[index].withUpdatedText(newText)
    }

    private var totalSpeechDuration: CMTime {
        cues.reduce(CMTime.zero) { CMTimeAdd($0, $1.duration) }
    }

    private func formatDuration(_ time: CMTime) -> String {
        guard time.isValid, !time.isIndefinite else { return "0s" }
        let sec = CMTimeGetSeconds(time)
        return String(format: "%.1fs", sec)
    }
}
