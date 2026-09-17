import SwiftUI
import CoreMedia
import MacDubCore

public struct SMPTERulerView: View {
    @ObservedObject var viewModel: TimelineViewModel

    public init(viewModel: TimelineViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GeometryReader { geometry in
            let totalWidth = viewModel.converter.timeToX(viewModel.totalDuration)
            let visibleRect = CGRect(
                x: viewModel.scrollOffsetX,
                y: 0,
                width: max(geometry.size.width, viewModel.viewportWidth),
                height: 28
            )
            let ticks = viewModel.rulerFormatter.generateTicks(
                visibleRect: visibleRect,
                pixelsPerSecond: viewModel.pixelsPerSecond,
                totalDuration: viewModel.totalDuration
            )

            ZStack(alignment: .topLeading) {
                // Ruler track background
                Rectangle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(width: max(geometry.size.width, totalWidth), height: 28)

                // Baseline separator
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: max(geometry.size.width, totalWidth), height: 1)
                    .offset(y: 27)

                // Render tick marks
                ForEach(ticks) { tick in
                    if tick.isMajor {
                        VStack(alignment: .leading, spacing: 2) {
                            if let label = tick.label {
                                Text(label)
                                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Rectangle()
                                .fill(Color.secondary)
                                .frame(width: 1, height: 10)
                        }
                        .offset(x: tick.pixelOffset, y: 3)
                    } else {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.5))
                            .frame(width: 1, height: 5)
                            .offset(x: tick.pixelOffset, y: 22)
                    }
                }
            }
            .frame(width: max(geometry.size.width, totalWidth), height: 28, alignment: .leading)
        }
        .frame(height: 28)
    }
}
