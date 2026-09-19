import SwiftUI
import CoreMedia
import AmendCore

public struct DurationFitView: View {
    public let availableDuration: CMTime
    public let generatedDuration: CMTime?
    public let state: CueEditState

    public init(
        availableDuration: CMTime,
        generatedDuration: CMTime? = nil,
        state: CueEditState = .original
    ) {
        self.availableDuration = availableDuration
        self.generatedDuration = generatedDuration
        self.state = state
    }

    private var availableSec: Double {
        max(0.01, CMTimeGetSeconds(availableDuration))
    }

    private var generatedSec: Double? {
        if let dur = generatedDuration, dur.isValid, !dur.isIndefinite {
            return CMTimeGetSeconds(dur)
        }
        if state == .synthesized || state == .forceFitted {
            return availableSec
        }
        return nil
    }

    private var isOverflow: Bool {
        if state == .overflowGated { return true }
        guard let gen = generatedSec else { return false }
        // 8% tolerance threshold as defined in ADR-0005
        return (gen - availableSec) / availableSec > 0.08
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DURATION FIT")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let gen = generatedSec {
                    if isOverflow {
                        let overflowDelta = max(0.0, gen - availableSec)
                        HStack(spacing: 3) {
                            Image(systemName: "exclamationmark.octagon.fill")
                                .font(.system(size: 10))
                            Text(String(format: "+%.2fs OVERFLOW", overflowDelta))
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(AmendTheme.statusError)
                    } else {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                            Text("FITS")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(AmendTheme.statusSuccess)
                    }
                }
            }

            // Metrics Grid
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Available Slot")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.2fs", availableSec))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                }

                if let gen = generatedSec {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Generated")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.2fs", gen))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(isOverflow ? AmendTheme.statusError : AmendTheme.statusSuccess)
                    }
                }
            }

            // Visual duration comparison bar
            GeometryReader { geo in
                let width = geo.size.width
                let maxRef = max(availableSec, (generatedSec ?? availableSec) * 1.05)
                let availableWidth = min(width, width * (availableSec / maxRef))

                ZStack(alignment: .leading) {
                    // Available slot background
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.10))
                        .frame(width: availableWidth, height: 6)

                    // Generated bar
                    if let gen = generatedSec {
                        let genWidth = min(width, width * (gen / maxRef))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(isOverflow ? AmendTheme.statusError : AmendTheme.statusSuccess)
                            .frame(width: genWidth, height: 6)
                    }
                }
            }
            .frame(height: 6)
        }
        .padding(10)
        .glassPanel(cornerRadius: AmendTheme.cornerRadiusMedium)
    }
}
