import SwiftUI
import CoreMedia
import AmendCore

public struct NarrationTimelineView: View {
    @ObservedObject public var viewModel: TimelineViewModel
    public let sourceURL: URL?
    public let waveform: MultiScaleWaveform?
    public let isSingleTrackAdvisory: Bool

    public init(
        viewModel: TimelineViewModel,
        sourceURL: URL? = nil,
        waveform: MultiScaleWaveform? = nil,
        isSingleTrackAdvisory: Bool = false
    ) {
        self.viewModel = viewModel
        self.sourceURL = sourceURL
        self.waveform = waveform
        self.isSingleTrackAdvisory = isSingleTrackAdvisory
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Main Timeline Track Scroll View
            GeometryReader { outerGeo in
                let totalWidth = max(outerGeo.size.width, viewModel.converter.timeToX(viewModel.totalDuration))
                let trackHeight: CGFloat = 186 // Ruler(28) + Filmstrip(50) + Waveform(60) + Cues(48)

                ScrollView(.horizontal, showsIndicators: true) {
                    ZStack(alignment: .topLeading) {
                        // Stacked Narration Tracks
                        VStack(alignment: .leading, spacing: 0) {
                            // 1. SMPTE Time Ruler (scrubbable)
                            SMPTERulerView(viewModel: viewModel)
                                .frame(width: totalWidth, height: 28)
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

                            // 2. Video Thumbnail Strip
                            FilmstripTrackView(viewModel: viewModel, sourceURL: sourceURL)
                                .frame(width: totalWidth, height: 50)

                            // 3. Narration Waveform
                            WaveformTrackView(viewModel: viewModel, waveform: waveform)
                                .frame(width: totalWidth, height: 60)

                            // 4. Cue Boundaries & Text Blocks
                            CueTrackView(viewModel: viewModel)
                                .frame(width: totalWidth, height: 48)
                        }
                        .frame(width: totalWidth, height: trackHeight, alignment: .leading)

                        // 5. High-precision Playhead Needle
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
            .background(AmendTheme.wellGraphite)

            Divider()

            // Bottom Transport & Zoom Toolbar
            HStack(spacing: 12) {
                // Play / Pause
                Button(action: {
                    viewModel.clock.togglePlayPause()
                }) {
                    Image(systemName: viewModel.clock.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AmendTheme.accent)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Toggle playback (Space)")

                // Timecode Readout
                Text(viewModel.rulerFormatter.string(from: viewModel.clock.currentTime))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(width: 95, alignment: .leading)

                // Single Audio Track Advisory (subtle banner near timeline as required by Phase 7)
                if isSingleTrackAdvisory {
                    HStack(spacing: 5) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(AmendTheme.statusWarning)

                        Text("Single Track: Narration replacement may affect embedded system audio")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AmendTheme.statusWarning.opacity(0.12))
                    .clipShape(Capsule())
                }

                Spacer()

                GlassEffectContainer {
                    HStack(spacing: 12) {
                        // Magnetic Snapping Toggle
                        Button(action: {
                            viewModel.isSnappingEnabled.toggle()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "magnet")
                                    .font(.system(size: 11))
                                Text("Snap")
                                    .font(.system(size: 11))
                            }
                            .foregroundStyle(viewModel.isSnappingEnabled ? AmendTheme.accent : .secondary)
                        }
                        .buttonStyle(GlassButtonStyle())
                        .help("Toggle Playhead Magnetic Snapping")

                        Divider()
                            .frame(height: 14)

                        // Zoom Controls
                        HStack(spacing: 6) {
                            Image(systemName: "minus.magnifyingglass")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)

                            Slider(
                                value: Binding<Double>(
                                    get: { viewModel.pixelsPerSecond },
                                    set: { viewModel.applyZoom(newPPS: $0, anchorViewportX: viewModel.viewportWidth / 2.0) }
                                ),
                                in: 10.0...1000.0
                            )
                            .frame(width: 110)
                            .controlSize(.mini)

                            Image(systemName: "plus.magnifyingglass")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .glassEffect(.regular)
        }
    }
}
