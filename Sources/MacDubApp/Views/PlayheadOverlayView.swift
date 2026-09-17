import SwiftUI
import CoreMedia

public struct PlayheadOverlayView: View {
    @ObservedObject var playheadClock: PlayheadClock
    public let totalHeight: CGFloat
    public let onScrubDrag: (Double) -> Void
    public let onScrubEnd: () -> Void

    public init(
        playheadClock: PlayheadClock,
        totalHeight: CGFloat,
        onScrubDrag: @escaping (Double) -> Void,
        onScrubEnd: @escaping () -> Void
    ) {
        self.playheadClock = playheadClock
        self.totalHeight = totalHeight
        self.onScrubDrag = onScrubDrag
        self.onScrubEnd = onScrubEnd
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            // 2pt Needle Line
            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: totalHeight)
                .offset(x: CGFloat(playheadClock.playheadX) - 1.0, y: 0)

            // Scrubber Top Cap Handle
            PlayheadCapShape()
                .fill(Color.red)
                .frame(width: 14, height: 16)
                .offset(x: CGFloat(playheadClock.playheadX) - 7.0, y: 0)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            onScrubDrag(Double(value.location.x))
                        }
                        .onEnded { _ in
                            onScrubEnd()
                        }
                )
        }
        .allowsHitTesting(true)
    }
}

public struct PlayheadCapShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}
