import SwiftUI
import CoreMedia
import MacDubCore

public struct CueTrackView: View {
    @ObservedObject var viewModel: TimelineViewModel

    public init(viewModel: TimelineViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GeometryReader { geometry in
            let totalWidth = viewModel.converter.timeToX(viewModel.totalDuration)
            let visibleCues = visibleCuesInViewport()

            ZStack(alignment: .leading) {
                // Background Track Bar
                Rectangle()
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                    .frame(width: max(geometry.size.width, totalWidth), height: 48)

                // Virtualized Cue Blocks
                ForEach(visibleCues) { cue in
                    CueBlockView(
                        cue: cue,
                        converter: viewModel.converter,
                        isSelected: viewModel.selectedCueID == cue.id,
                        isActive: viewModel.activeCueID == cue.id,
                        onSelect: { viewModel.selectCue(cue) }
                    )
                }
            }
            .frame(width: max(geometry.size.width, totalWidth), height: 48, alignment: .leading)
        }
        .frame(height: 48)
    }

    private func visibleCuesInViewport() -> [Cue] {
        let startX = max(0.0, viewModel.scrollOffsetX - 200.0)
        let endX = viewModel.scrollOffsetX + viewModel.viewportWidth + 200.0
        let startTime = viewModel.converter.xToTime(startX)
        let endTime = viewModel.converter.xToTime(endX)

        guard let range = viewModel.cues.cueIndexRange(intersecting: startTime, endTime: endTime) else {
            return []
        }
        return Array(viewModel.cues[range])
    }
}
