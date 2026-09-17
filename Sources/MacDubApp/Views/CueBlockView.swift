import SwiftUI
import CoreMedia
import MacDubCore

public struct CueBlockView: View {
    public let cue: Cue
    public let converter: TimelineCoordinateConverter
    public let isSelected: Bool
    public let isActive: Bool
    public let onSelect: () -> Void

    public init(
        cue: Cue,
        converter: TimelineCoordinateConverter,
        isSelected: Bool,
        isActive: Bool,
        onSelect: @escaping () -> Void
    ) {
        self.cue = cue
        self.converter = converter
        self.isSelected = isSelected
        self.isActive = isActive
        self.onSelect = onSelect
    }

    public var body: some View {
        let rect = converter.timeRangeToRect(cue.timeRange, height: 44, y: 2)

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(borderColor, lineWidth: isSelected ? 2.0 : 1.0)
                )

            // Content Label
            if rect.width >= 18 {
                HStack(spacing: 4) {
                    if cue.editState == .overflowGated {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 10))
                    }

                    if rect.width >= 50 {
                        Text(cue.text)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundColor(.primary)

                        Spacer(minLength: 0)

                        if rect.width >= 100 {
                            let durationSec = CMTimeGetSeconds(cue.duration)
                            Text(String(format: "%.2fs", durationSec))
                                .font(.system(size: 9, weight: .regular))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .frame(width: max(2.0, rect.width), height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .help("Word: '\(cue.text)'\nDuration: \(String(format: "%.3fs", CMTimeGetSeconds(cue.duration)))\nState: \(cue.editState.rawValue)")
    }

    private var backgroundColor: Color {
        if isActive {
            return stateBaseColor.opacity(0.40)
        }
        return stateBaseColor.opacity(0.20)
    }

    private var borderColor: Color {
        if isSelected {
            return Color.accentColor
        }
        if isActive {
            return Color.white.opacity(0.85)
        }
        return stateBaseColor.opacity(0.80)
    }

    private var stateBaseColor: Color {
        switch cue.editState {
        case .original:
            return .blue
        case .edited:
            return .orange
        case .synthesized:
            return .green
        case .overflowGated:
            return .red
        case .forceFitted:
            return .purple
        }
    }
}
