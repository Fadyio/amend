import SwiftUI
import CoreMedia
import MacDubCore

public struct CueInspectorView: View {
    public let cue: Cue?
    public let cueIndex: Int?
    public let totalCues: Int
    @Binding public var selectedProvider: SynthesisProviderType
    public let referenceVoice: ReferenceVoice?
    public let isSynthesizing: Bool
    public let isRewriting: Bool

    public let onSynthesize: () -> Void
    public let onPreviewAudio: () -> Void
    public let onForceFit: () -> Void
    public let onDiscardCandidate: () -> Void
    public let onSplitCue: () -> Void
    public let onRestoreOriginal: () -> Void
    public let onTriggerRewrite: (GrammarAction, String) -> Void
    public let onOpenSettings: () -> Void
    public let onImportReferenceVoice: () -> Void

    public init(
        cue: Cue?,
        cueIndex: Int?,
        totalCues: Int,
        selectedProvider: Binding<SynthesisProviderType>,
        referenceVoice: ReferenceVoice? = nil,
        isSynthesizing: Bool = false,
        isRewriting: Bool = false,
        onSynthesize: @escaping () -> Void = {},
        onPreviewAudio: @escaping () -> Void = {},
        onForceFit: @escaping () -> Void = {},
        onDiscardCandidate: @escaping () -> Void = {},
        onSplitCue: @escaping () -> Void = {},
        onRestoreOriginal: @escaping () -> Void = {},
        onTriggerRewrite: @escaping (GrammarAction, String) -> Void = { _, _ in },
        onOpenSettings: @escaping () -> Void = {},
        onImportReferenceVoice: @escaping () -> Void = {}
    ) {
        self.cue = cue
        self.cueIndex = cueIndex
        self.totalCues = totalCues
        self._selectedProvider = selectedProvider
        self.referenceVoice = referenceVoice
        self.isSynthesizing = isSynthesizing
        self.isRewriting = isRewriting
        self.onSynthesize = onSynthesize
        self.onPreviewAudio = onPreviewAudio
        self.onForceFit = onForceFit
        self.onDiscardCandidate = onDiscardCandidate
        self.onSplitCue = onSplitCue
        self.onRestoreOriginal = onRestoreOriginal
        self.onTriggerRewrite = onTriggerRewrite
        self.onOpenSettings = onOpenSettings
        self.onImportReferenceVoice = onImportReferenceVoice
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let cue = cue, let index = cueIndex {
                    // Header / Cue identification
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cue #\(index + 1)")
                                .font(.headline.bold())
                                .foregroundStyle(.primary)

                            Text("\(formatTime(cue.start)) → \(formatTime(cue.end))")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        StatusBadge(state: cue.editState, overflowDelta: cue.overflowDelta)
                    }

                    Divider()

                    // Voice Selection (Phase 11 & 12)
                    VoicePickerView(
                        selectedProvider: $selectedProvider,
                        referenceVoice: referenceVoice,
                        onOpenSettings: onOpenSettings,
                        onImportReferenceVoice: onImportReferenceVoice
                    )

                    Divider()

                    // Duration Fit Section (Phase 5)
                    DurationFitView(
                        availableDuration: cue.duration,
                        generatedDuration: cue.generatedDuration ?? (cue.overflowDelta.map { CMTimeAdd(cue.duration, $0) } ?? (cue.audioWAVRelativePath != nil ? cue.duration : nil)),
                        state: cue.editState
                    )

                    // Overflow actions (Phase 5: Rewrite, Force Fit, Split Cue, Discard Candidate)
                    if cue.editState == .overflowGated {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("OVERFLOW RESOLUTION")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(MacDubTheme.statusError)

                            Text("Generated audio exceeds available time slot. Choose an action to resolve:")
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                                GridRow {
                                    Button(action: {
                                        onTriggerRewrite(.rewriteToFit(targetDuration: cue.duration), "Rewrite to Fit Duration")
                                    }) {
                                        Label("Rewrite to Fit", systemImage: "wand.and.stars")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(GlassButtonStyle(isProminent: true))

                                    Button(action: onForceFit) {
                                        Label("Force Fit", systemImage: "arrow.left.and.right.circle")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(GlassButtonStyle())
                                }

                                GridRow {
                                    Button(action: onSplitCue) {
                                        Label("Split Cue", systemImage: "scissors")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(GlassButtonStyle())

                                    Button(action: onDiscardCandidate) {
                                        Label("Discard Candidate", systemImage: "xmark.circle")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(GlassButtonStyle())
                                }
                            }
                        }
                        .padding(10)
                        .glassPanel(cornerRadius: MacDubTheme.cornerRadiusMedium)
                    }

                    Divider()

                    // AI Text Actions
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TEXT ACTIONS")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)

                        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                            GridRow {
                                Button(action: {
                                    onTriggerRewrite(.fixGrammar, "Fix Grammar")
                                }) {
                                    Label("Fix Grammar", systemImage: "checkmark.bubble")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(GlassButtonStyle())
                                .disabled(isRewriting)

                                Button(action: {
                                    onTriggerRewrite(.makeNatural, "Make Natural")
                                }) {
                                    Label("Make Natural", systemImage: "sparkles")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(GlassButtonStyle())
                                .disabled(isRewriting)
                            }

                            GridRow {
                                Button(action: {
                                    onTriggerRewrite(.rewriteToFit(targetDuration: cue.duration), "Rewrite to Fit")
                                }) {
                                    Label("Rewrite to Fit", systemImage: "arrow.down.right.and.arrow.up.left")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(GlassButtonStyle())
                                .disabled(isRewriting)

                                if cue.editState != .original {
                                    Button(action: onRestoreOriginal) {
                                        Label("Restore Original", systemImage: "arrow.uturn.backward")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(GlassButtonStyle())
                                }
                            }
                        }
                    }

                    Divider()

                    // Synthesis Controls
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SYNTHESIS")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            Button(action: onSynthesize) {
                                HStack(spacing: 6) {
                                    if isSynthesizing {
                                        ProgressView()
                                            .controlSize(.mini)
                                    } else {
                                        Image(systemName: cue.editState == .synthesized ? "arrow.clockwise" : "waveform.badge.plus")
                                    }
                                    Text(cue.editState == .synthesized ? "Regenerate" : "Generate Voice")
                                }
                            }
                            .buttonStyle(GlassButtonStyle(isProminent: true))
                            .disabled(isSynthesizing)
                            .keyboardShortcut(.return, modifiers: .command)

                            if cue.editState == .synthesized {
                                Button(action: onPreviewAudio) {
                                    Label("Preview", systemImage: "speaker.wave.2")
                                }
                                .buttonStyle(GlassButtonStyle())
                            }

                            Button(action: onSplitCue) {
                                Label("Split Cue", systemImage: "scissors")
                            }
                            .buttonStyle(GlassButtonStyle())
                        }
                    }

                } else {
                    // Empty selection state
                    VStack(spacing: 12) {
                        Image(systemName: "hand.tap")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)

                        VStack(spacing: 4) {
                            Text("Select narration to edit")
                                .font(.headline)
                                .foregroundStyle(.primary)

                            Text("Choose a paragraph in the script\nor click a Cue in the timeline.")
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(14)
        }
        .background(.ultraThinMaterial)
        .background(MacDubTheme.panelGraphite.opacity(0.40))
        .overlay(
            Rectangle()
                .fill(LinearGradient(
                    colors: [Color.white.opacity(0.12), Color.white.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .frame(width: 1),
            alignment: .leading
        )
    }

    private func formatTime(_ time: CMTime) -> String {
        guard time.isValid, !time.isIndefinite else { return "00:00.00" }
        let totalSeconds = CMTimeGetSeconds(time)
        let minutes = Int(totalSeconds) / 60
        let seconds = totalSeconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%05.2f", minutes, seconds)
    }
}
