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
                .fill(Color(red: 0.2, green: 0.55, blue: 1.0))
                .frame(width: 2, height: totalHeight)
                .offset(x: CGFloat(playheadClock.playheadX) - 1.0, y: 0)
                .shadow(color: Color.blue.opacity(0.6), radius: 3, x: 0, y: 0)

            // Scrubber Top Cap Handle
            PlayheadCapShape()
                .fill(Color(red: 0.2, green: 0.55, blue: 1.0))
                .frame(width: 14, height: 16)
                .shadow(color: Color.black.opacity(0.4), radius: 2, x: 0, y: 1)
                .offset(x: CGFloat(playheadClock.playheadX) - 7.0, y: 0)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if playheadClock.dragStartX == nil {
                                playheadClock.dragStartX = playheadClock.playheadX
                            }
                            let effectiveX = max(0.0, (playheadClock.dragStartX ?? playheadClock.playheadX) + Double(value.translation.width))
                            onScrubDrag(effectiveX)
                        }
                        .onEnded { _ in
                            playheadClock.dragStartX = nil
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
