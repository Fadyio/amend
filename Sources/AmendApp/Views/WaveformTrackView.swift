import SwiftUI
import CoreMedia
import AmendCore

public struct WaveformTrackView: View {
    @ObservedObject var viewModel: TimelineViewModel
    public let waveform: MultiScaleWaveform?

    public init(viewModel: TimelineViewModel, waveform: MultiScaleWaveform?) {
        self.viewModel = viewModel
        self.waveform = waveform
    }

    public var body: some View {
        GeometryReader { geometry in
            let totalWidth = viewModel.converter.timeToX(viewModel.totalDuration)
            let trackWidth = max(geometry.size.width, totalWidth)

            ZStack(alignment: .leading) {
                // Background Track
                Rectangle()
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                    .frame(width: trackWidth, height: 60)

                // Midline
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: trackWidth, height: 1)
                    .offset(y: 29.5)

                // Waveform Peaks
                if let wf = waveform, trackWidth > 0 {
                    Canvas { context, size in
                        let midY = size.height / 2.0
                        let maxAmp = midY - 2.0
                        let timeRange = CMTimeRange(start: .zero, duration: viewModel.totalDuration)
                        let intWidth = max(1, Int(size.width))
                        let peaks = wf.renderPeaks(for: timeRange, pixelWidth: intWidth)

                        var path = Path()
                        for (x, peak) in peaks.enumerated() {
                            let topY = midY - CGFloat(peak.maxSample) * maxAmp
                            let bottomY = midY - CGFloat(peak.minSample) * maxAmp
                            let barHeight = max(1.0, bottomY - topY)
                            path.addRect(CGRect(x: CGFloat(x), y: topY, width: 1.0, height: barHeight))
                        }

                        context.fill(path, with: .color(Color.accentColor.opacity(0.75)))
                    }
                    .frame(width: trackWidth, height: 60)
                }
            }
            .frame(width: trackWidth, height: 60, alignment: .leading)
        }
        .frame(height: 60)
    }
}
