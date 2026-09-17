import SwiftUI
import AVKit
import AVFoundation

public struct VideoPlayerView: NSViewRepresentable {
    private let player: AVPlayer

    public init(player: AVPlayer) {
        self.player = player
    }

    public func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .none // Transport controls handled by MacDub timeline
        playerView.videoGravity = .resizeAspect
        playerView.allowsPictureInPicturePlayback = false
        return playerView
    }

    public func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
