import SwiftUI
import CoreMedia
import MacDubCore

public struct FilmstripTrackView: View {
    @ObservedObject var viewModel: TimelineViewModel
    public let sourceURL: URL?

    public init(
        viewModel: TimelineViewModel,
        sourceURL: URL?
    ) {
        self.viewModel = viewModel
        self.sourceURL = sourceURL
    }

    public var body: some View {
        GeometryReader { geometry in
            let totalWidth = viewModel.converter.timeToX(viewModel.totalDuration)

            ZStack(alignment: .leading) {
                // Background Track
                Rectangle()
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                    .frame(width: max(geometry.size.width, totalWidth), height: 50)

                // Loaded Thumbnails
                ForEach(viewModel.thumbnails) { thumb in
                    Image(decorative: thumb.image, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: thumb.bounds.width, height: 50)
                        .clipped()
                        .offset(x: thumb.bounds.origin.x, y: 0)
                }
            }
            .frame(width: max(geometry.size.width, totalWidth), height: 50, alignment: .leading)
            .onAppear {
                viewModel.reloadThumbnails(for: sourceURL)
            }
            .onChange(of: viewModel.pixelsPerSecond) {
                viewModel.reloadThumbnails(for: sourceURL)
            }
            .onChange(of: viewModel.scrollOffsetX) {
                viewModel.reloadThumbnails(for: sourceURL)
            }
        }
        .frame(height: 50)
    }
}
