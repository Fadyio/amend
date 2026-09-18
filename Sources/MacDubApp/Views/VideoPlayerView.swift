import SwiftUI
import AppKit
import AVFoundation

/// Native AppKit-backed video reference view leveraging AVPlayerLayer for seamless,
/// aspect-fit video playback without UI lag, clipping, or transport interception.
public final class MacDubPlayerNSView: NSView {
    public let playerLayer = AVPlayerLayer()

    public var player: AVPlayer? {
        get { playerLayer.player }
        set {
            if playerLayer.player !== newValue {
                playerLayer.player = newValue
            }
        }
    }

    public init(player: AVPlayer?) {
        super.init(frame: .zero)
        setup(player: player)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup(player: nil)
    }

    private func setup(player: AVPlayer?) {
        wantsLayer = true
        let hostLayer = CALayer()
        hostLayer.backgroundColor = NSColor.black.cgColor
        self.layer = hostLayer

        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        playerLayer.needsDisplayOnBoundsChange = true
        playerLayer.backgroundColor = NSColor.black.cgColor
        hostLayer.addSublayer(playerLayer)
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

/// SwiftUI wrapper for native video reference monitor.
public struct VideoPlayerView: NSViewRepresentable {
    public let player: AVPlayer?

    public init(player: AVPlayer?) {
        self.player = player
    }

    public func makeNSView(context: Context) -> MacDubPlayerNSView {
        let view = MacDubPlayerNSView(player: player)
        return view
    }

    public func updateNSView(_ nsView: MacDubPlayerNSView, context: Context) {
        nsView.player = player
    }
}
