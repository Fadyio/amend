import SwiftUI
import AppKit
import CoreMedia
import MacDubCore

public enum MacDubTheme {
    // Backgrounds & Bases
    public static let baseGraphite = Color(red: 0.09, green: 0.10, blue: 0.12)
    public static let panelGraphite = Color(red: 0.12, green: 0.13, blue: 0.16)
    public static let wellGraphite = Color(red: 0.06, green: 0.07, blue: 0.08)

    // Primary Accent: Restrained Electric Cobalt Blue
    public static let accent = Color(red: 0.18, green: 0.50, blue: 0.98)
    public static let accentMuted = Color(red: 0.18, green: 0.50, blue: 0.98).opacity(0.20)
    public static let accentSubtle = Color(red: 0.18, green: 0.50, blue: 0.98).opacity(0.08)

    // Semantic Status Colors
    public static let statusSuccess = Color(red: 0.22, green: 0.80, blue: 0.50) // Green: fit / synthesized
    public static let statusWarning = Color(red: 0.96, green: 0.65, blue: 0.20) // Amber: modified / edited
    public static let statusError = Color(red: 0.94, green: 0.32, blue: 0.32)   // Red: overflow / error
    public static let statusActive = Color(red: 0.18, green: 0.50, blue: 0.98)  // Blue: active / playing

    // Subtle Glass Borders & Dividers
    public static let glassBorder = Color.white.opacity(0.10)
    public static let glassBorderSubtle = Color.white.opacity(0.05)
    public static let glassBorderActive = Color(red: 0.18, green: 0.50, blue: 0.98).opacity(0.60)

    public static let cornerRadiusLarge: CGFloat = 12.0
    public static let cornerRadiusMedium: CGFloat = 8.0
    public static let cornerRadiusSmall: CGFloat = 5.0
}

// MARK: - Reusable View Modifiers

public struct GlassPanelModifier: ViewModifier {
    public let cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = MacDubTheme.cornerRadiusMedium) {
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial)
            .background(MacDubTheme.panelGraphite.opacity(0.60))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.18), Color.white.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
    }
}

public struct ElevatedGlassPanelModifier: ViewModifier {
    public let cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = MacDubTheme.cornerRadiusLarge) {
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        content
            .background(.thinMaterial)
            .background(MacDubTheme.panelGraphite.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.24), Color.white.opacity(0.06), Color.white.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 5)
    }
}

public struct SelectedGlassSurfaceModifier: ViewModifier {
    public let isSelected: Bool
    public let isActive: Bool
    public let cornerRadius: CGFloat

    public init(
        isSelected: Bool,
        isActive: Bool = false,
        cornerRadius: CGFloat = MacDubTheme.cornerRadiusMedium
    ) {
        self.isSelected = isSelected
        self.isActive = isActive
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        content
            .background(
                isSelected
                    ? MacDubTheme.accentMuted
                    : (isActive ? MacDubTheme.accentSubtle : Color.clear)
            )
            .background(isSelected ? AnyShapeStyle(.ultraThinMaterial) : (isActive ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(Color.clear)))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        isSelected
                            ? LinearGradient(
                                colors: [MacDubTheme.accent.opacity(0.90), MacDubTheme.accent.opacity(0.45)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            : (isActive ? LinearGradient(colors: [Color.white.opacity(0.25), Color.white.opacity(0.08)], startPoint: .top, endPoint: .bottom) : LinearGradient(colors: [Color.clear], startPoint: .top, endPoint: .bottom)),
                        lineWidth: isSelected ? 1.5 : 1.0
                    )
            )
            .shadow(color: isSelected ? MacDubTheme.accent.opacity(0.18) : Color.clear, radius: 8, x: 0, y: 2)
    }
}

public extension View {
    func glassPanel(cornerRadius: CGFloat = MacDubTheme.cornerRadiusMedium) -> some View {
        modifier(GlassPanelModifier(cornerRadius: cornerRadius))
    }

    func elevatedGlassPanel(cornerRadius: CGFloat = MacDubTheme.cornerRadiusLarge) -> some View {
        modifier(ElevatedGlassPanelModifier(cornerRadius: cornerRadius))
    }

    func selectedGlassSurface(
        isSelected: Bool,
        isActive: Bool = false,
        cornerRadius: CGFloat = MacDubTheme.cornerRadiusMedium
    ) -> some View {
        modifier(SelectedGlassSurfaceModifier(isSelected: isSelected, isActive: isActive, cornerRadius: cornerRadius))
    }
}

// MARK: - Pill Status Badge

public struct StatusBadge: View {
    public let state: CueEditState
    public let overflowDelta: CMTime?

    public init(state: CueEditState, overflowDelta: CMTime? = nil) {
        self.state = state
        self.overflowDelta = overflowDelta
    }

    public var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 6, height: 6)

            Text(labelText)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(indicatorColor)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(indicatorColor.opacity(0.12))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(indicatorColor.opacity(0.28), lineWidth: 0.75)
        )
    }

    private var labelText: String {
        switch state {
        case .original:
            return "Original"
        case .edited:
            return "Edited"
        case .synthesized:
            return "Synthesized"
        case .overflowGated:
            if let delta = overflowDelta, delta > .zero {
                return String(format: "+%.2fs Overflow", CMTimeGetSeconds(delta))
            }
            return "Overflow Gated"
        case .forceFitted:
            return "Force-Fitted"
        }
    }

    private var indicatorColor: Color {
        switch state {
        case .original:
            return Color.secondary
        case .edited:
            return MacDubTheme.statusWarning
        case .synthesized:
            return MacDubTheme.statusSuccess
        case .overflowGated:
            return MacDubTheme.statusError
        case .forceFitted:
            return Color.purple
        }
    }
}

// MARK: - Glass Button Style

public struct GlassButtonStyle: ButtonStyle {
    public let isProminent: Bool

    public init(isProminent: Bool = false) {
        self.isProminent = isProminent
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: isProminent ? .semibold : .medium))
            .foregroundStyle(isProminent ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isProminent
                    ? MacDubTheme.accent.opacity(configuration.isPressed ? 0.75 : 0.90)
                    : Color.white.opacity(configuration.isPressed ? 0.15 : 0.08)
            )
            .clipShape(RoundedRectangle(cornerRadius: MacDubTheme.cornerRadiusSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MacDubTheme.cornerRadiusSmall, style: .continuous)
                    .stroke(
                        isProminent
                            ? LinearGradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0.10)], startPoint: .top, endPoint: .bottom)
                            : LinearGradient(colors: [Color.white.opacity(0.18), Color.white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
            )
            .shadow(color: isProminent ? MacDubTheme.accent.opacity(0.25) : Color.clear, radius: 4, x: 0, y: 2)
    }
}
