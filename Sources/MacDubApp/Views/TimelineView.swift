import SwiftUI
import CoreMedia
import MacDubCore

public struct TimelineView: View {
    @ObservedObject var viewModel: TimelineViewModel
    public let sourceURL: URL?
    public let waveform: MultiScaleWaveform?

    public init(
        viewModel: TimelineViewModel,
        sourceURL: URL? = nil,
        waveform: MultiScaleWaveform? = nil
    ) {
        self.viewModel = viewModel
        self.sourceURL = sourceURL
        self.waveform = waveform
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Main Track Scroll Area
            GeometryReader { outerGeo in
                let totalWidth = max(outerGeo.size.width, viewModel.converter.timeToX(viewModel.totalDuration))
                let trackHeight: CGFloat = 186 // 28 + 50 + 60 + 48

                ScrollView(.horizontal, showsIndicators: true) {
                    ZStack(alignment: .topLeading) {
                        // Stacked Tracks
                        VStack(alignment: .leading, spacing: 0) {
                            SMPTERulerView(viewModel: viewModel)
                            FilmstripTrackView(viewModel: viewModel, sourceURL: sourceURL)
                            WaveformTrackView(viewModel: viewModel, waveform: waveform)
                            CueTrackView(viewModel: viewModel)
                        }
                        .frame(width: totalWidth, height: trackHeight, alignment: .leading)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if !viewModel.isScrubbing {
                                        viewModel.beginScrubbing()
                                    }
                                    viewModel.updateScrub(to: Double(value.location.x))
                                }
                                .onEnded { _ in
                                    viewModel.endScrubbing()
                                }
                        )

                        // 60Hz Isolated Playhead Overlay
                        PlayheadOverlayView(
                            playheadClock: viewModel.playheadClock,
                            totalHeight: trackHeight,
                            onScrubDrag: { x in
                                if !viewModel.isScrubbing {
                                    viewModel.beginScrubbing()
                                }
                                viewModel.updateScrub(to: x)
                            },
                            onScrubEnd: {
                                viewModel.endScrubbing()
                            }
                        )
                    }
                    .frame(width: totalWidth, height: trackHeight, alignment: .leading)
                }
                .onAppear {
                    viewModel.viewportWidth = Double(outerGeo.size.width)
                }
                .onChange(of: outerGeo.size.width) { _, newWidth in
                    viewModel.viewportWidth = Double(newWidth)
                }
            }
            .frame(height: 186)

            Divider()

            // Transport & Zoom Control Bar
            HStack(spacing: 12) {
                // Play / Pause Button
                Button(action: {
                    viewModel.clock.togglePlayPause()
                }) {
                    Image(systemName: viewModel.clock.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .help("Toggle Play/Pause (Space)")

                // Timecode Readout
                Text(viewModel.rulerFormatter.string(from: viewModel.clock.currentTime))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
                    .frame(width: 90, alignment: .leading)

                Spacer()

                // Magnetic Snapping Toggle
                Button(action: {
                    viewModel.isSnappingEnabled.toggle()
                }) {
                    Image(systemName: viewModel.isSnappingEnabled ? "magnet.fill" : "magnet")
                        .font(.system(size: 13))
                        .foregroundColor(viewModel.isSnappingEnabled ? .accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help(viewModel.isSnappingEnabled ? "Snapping Enabled" : "Snapping Disabled")

                // Zoom Out
                Button(action: {
                    let currentPPS = viewModel.pixelsPerSecond
                    let newPPS = max(10.0, currentPPS / 1.5)
                    viewModel.applyZoom(newPPS: newPPS, anchorViewportX: viewModel.viewportWidth / 2.0)
                }) {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)

                // Logarithmic Zoom Slider (10 to 1000 px/s)
                Slider(value: Binding(
                    get: {
                        TimelineCoordinateConverter.normalizedScale(fromPPS: viewModel.pixelsPerSecond)
                    },
                    set: { newScale in
                        let newPPS = TimelineCoordinateConverter.pps(fromNormalizedScale: newScale)
                        viewModel.applyZoom(newPPS: newPPS, anchorViewportX: viewModel.viewportWidth / 2.0)
                    }
                ), in: 0.0...1.0)
                .frame(width: 140)

                // Zoom In
                Button(action: {
                    let currentPPS = viewModel.pixelsPerSecond
                    let newPPS = min(1000.0, currentPPS * 1.5)
                    viewModel.applyZoom(newPPS: newPPS, anchorViewportX: viewModel.viewportWidth / 2.0)
                }) {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
