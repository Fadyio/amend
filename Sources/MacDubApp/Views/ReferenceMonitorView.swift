import SwiftUI
import CoreMedia
import AVFoundation
import MacDubCore

public struct ReferenceMonitorView: View {
    public let player: AVPlayer?
    public let currentTime: CMTime
    public let totalDuration: CMTime
    public let isPlaying: Bool
    public let videoAspectRatio: CGFloat
    public let onTogglePlayPause: () -> Void
    public let onStepBackward: () -> Void
    public let onStepForward: () -> Void

    @Binding public var isExpandedPopoverPresented: Bool

    public init(
        player: AVPlayer?,
        currentTime: CMTime,
        totalDuration: CMTime,
        isPlaying: Bool,
        videoAspectRatio: CGFloat = 16.0 / 9.0,
        isExpandedPopoverPresented: Binding<Bool> = .constant(false),
        onTogglePlayPause: @escaping () -> Void,
        onStepBackward: @escaping () -> Void,
        onStepForward: @escaping () -> Void
    ) {
        self.player = player
        self.currentTime = currentTime
        self.totalDuration = totalDuration
        self.isPlaying = isPlaying
        self.videoAspectRatio = videoAspectRatio > 0 ? videoAspectRatio : (16.0 / 9.0)
        self._isExpandedPopoverPresented = isExpandedPopoverPresented
        self.onTogglePlayPause = onTogglePlayPause
        self.onStepBackward = onStepBackward
        self.onStepForward = onStepForward
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack {
                HStack(spacing: 5) {
                    Circle()
                        .fill(isPlaying ? MacDubTheme.statusSuccess : Color.secondary)
                        .frame(width: 7, height: 7)

                    Text("REFERENCE MONITOR")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Compact Timecode Readout
                HStack(spacing: 3) {
                    Text(formatTime(currentTime))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)

                    Text("/")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text(formatTime(totalDuration))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                // Full-size Popover / Expand Button (Phase 8)
                Button(action: { isExpandedPopoverPresented.toggle() }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 6)
                }
                .buttonStyle(.plain)
                .help("Open expanded reference popover")
                .popover(isPresented: $isExpandedPopoverPresented, arrowEdge: .bottom) {
                    VStack(spacing: 8) {
                        HStack {
                            Text("Reference Monitor — Expanded")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Done") {
                                isExpandedPopoverPresented = false
                            }
                            .buttonStyle(GlassButtonStyle())
                            .controlSize(.mini)
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 8)

                        ZStack {
                            Color.black
                            if let player = player {
                                VideoPlayerView(player: player)
                            }
                        }
                        .aspectRatio(videoAspectRatio, contentMode: .fit)
                        .frame(minWidth: 480, idealWidth: 640, maxWidth: 800, minHeight: 270, idealHeight: 360, maxHeight: 450)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .padding(8)
                    .background(MacDubTheme.baseGraphite)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            // Video Display Well
            ZStack {
                Color.black

                if let player = player {
                    VideoPlayerView(player: player)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "video.slash")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        Text("No video loaded")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .aspectRatio(videoAspectRatio, contentMode: .fit)
            .frame(minHeight: 140, maxHeight: 280)
            .clipped()

            // Mini Transport Bar
            HStack(spacing: 12) {
                // -5s Step
                Button(action: onStepBackward) {
                    Image(systemName: "gobackward.5")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Step back 5 seconds")

                // Play / Pause
                Button(action: onTogglePlayPause) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(MacDubTheme.accent)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Toggle playback (Space)")

                // +5s Step
                Button(action: onStepForward) {
                    Image(systemName: "goforward.5")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Step forward 5 seconds")

                Spacer()

                Text("Sync Reference Only")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
        }
        .elevatedGlassPanel(cornerRadius: MacDubTheme.cornerRadiusLarge)
    }

    private func formatTime(_ time: CMTime) -> String {
        guard time.isValid, !time.isIndefinite else { return "00:00.00" }
        let totalSeconds = CMTimeGetSeconds(time)
        let minutes = Int(totalSeconds) / 60
        let seconds = totalSeconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%05.2f", minutes, seconds)
    }
}
