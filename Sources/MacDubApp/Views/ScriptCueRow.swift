import SwiftUI
import CoreMedia
import MacDubCore

public struct ScriptCueRow: View {
    public let cue: Cue
    public let index: Int
    public let isSelected: Bool
    public let isActive: Bool
    public let currentTime: CMTime
    public let onSelect: () -> Void
    public let onSeek: (CMTime) -> Void
    public let onUpdateText: (String) -> Void
    public let onTriggerRewrite: (GrammarAction, String) -> Void
    public let onRestoreOriginal: () -> Void
    public let onSynthesize: () -> Void

    @FocusState private var isFieldFocused: Bool

    public init(
        cue: Cue,
        index: Int,
        isSelected: Bool,
        isActive: Bool,
        currentTime: CMTime,
        onSelect: @escaping () -> Void,
        onSeek: @escaping (CMTime) -> Void,
        onUpdateText: @escaping (String) -> Void,
        onTriggerRewrite: @escaping (GrammarAction, String) -> Void = { _, _ in },
        onRestoreOriginal: @escaping () -> Void = {},
        onSynthesize: @escaping () -> Void = {}
    ) {
        self.cue = cue
        self.index = index
        self.isSelected = isSelected
        self.isActive = isActive
        self.currentTime = currentTime
        self.onSelect = onSelect
        self.onSeek = onSeek
        self.onUpdateText = onUpdateText
        self.onTriggerRewrite = onTriggerRewrite
        self.onRestoreOriginal = onRestoreOriginal
        self.onSynthesize = onSynthesize
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Metadata Header Line: Timestamp & Duration
            HStack(spacing: 8) {
                // Playhead association indicator
                if isActive {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(MacDubTheme.accent)
                } else if isSelected {
                    Circle()
                        .fill(MacDubTheme.accent)
                        .frame(width: 6, height: 6)
                }

                Text("#\(index + 1)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(isSelected ? MacDubTheme.accent : .secondary)

                Text("\(formatTime(cue.start)) — \(formatTime(cue.end))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(String(format: "%.2fs", CMTimeGetSeconds(cue.duration)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Spacer()

                StatusBadge(state: cue.editState, overflowDelta: cue.overflowDelta)
            }

            // Editable Narration Paragraph
            ZStack(alignment: .topLeading) {
                if isSelected {
                    // In-place editable text field for selected cue
                    TextField(
                        "Enter narration text...",
                        text: Binding<String>(
                            get: { cue.text },
                            set: { onUpdateText($0) }
                        ),
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .regular))
                    .lineSpacing(4)
                    .foregroundStyle(.primary)
                    .focused($isFieldFocused)
                } else {
                    // Document presentation view
                    Text(renderedParagraph)
                        .font(.system(size: 14, weight: .regular))
                        .lineSpacing(4)
                        .foregroundStyle(isActive ? .primary : Color.primary.opacity(0.88))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelect()
                            onSeek(cue.start)
                        }
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            isSelected
                ? MacDubTheme.accent.opacity(0.12)
                : (isActive ? Color.white.opacity(0.06) : Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: MacDubTheme.cornerRadiusMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MacDubTheme.cornerRadiusMedium, style: .continuous)
                .stroke(
                    isSelected
                        ? MacDubTheme.accent.opacity(0.40)
                        : (isActive ? Color.white.opacity(0.15) : Color.clear),
                    lineWidth: 1
                )
        )
        .contextMenu {
            Button("Fix Grammar") {
                onTriggerRewrite(.fixGrammar, "Fix Grammar")
            }
            Button("Make Natural") {
                onTriggerRewrite(.makeNatural, "Make Natural")
            }
            Button("Rewrite to Fit") {
                onTriggerRewrite(.rewriteToFit(targetDuration: cue.duration), "Rewrite to Fit")
            }
            if cue.editState != .original {
                Divider()
                Button("Restore Original") {
                    onRestoreOriginal()
                }
            }
            Divider()
            Button("Synthesize Voice") {
                onSynthesize()
            }
            Button("Seek to Cue Start") {
                onSeek(cue.start)
            }
        }
    }

    private var renderedParagraph: AttributedString {
        AttributedString(cue.text)
    }

    private func formatTime(_ time: CMTime) -> String {
        guard time.isValid, !time.isIndefinite else { return "00:00.00" }
        let totalSeconds = CMTimeGetSeconds(time)
        let minutes = Int(totalSeconds) / 60
        let seconds = totalSeconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%05.2f", minutes, seconds)
    }
}
