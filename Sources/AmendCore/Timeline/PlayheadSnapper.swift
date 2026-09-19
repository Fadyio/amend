import Foundation
import CoreMedia
import CoreGraphics

/// Represents the magnetic snapping result for playhead scrubbing.
public struct SnapResult: Equatable, Sendable {
    public let snappedTime: CMTime
    public let isSnapped: Bool
    public let snappedTarget: CMTime?
    public let distancePixels: CGFloat

    public init(snappedTime: CMTime, isSnapped: Bool, snappedTarget: CMTime?, distancePixels: CGFloat) {
        self.snappedTime = snappedTime
        self.isSnapped = isSnapped
        self.snappedTarget = snappedTarget
        self.distancePixels = distancePixels
    }
}

/// Snap engine managing cue boundary targets, zoom-aware tolerance, and dual-threshold hysteresis.
public final class PlayheadSnapper {
    public var pixelThreshold: CGFloat
    public var releaseThresholdFactor: CGFloat

    private var currentSnappedTarget: CMTime?

    public init(pixelThreshold: CGFloat = 8.0, releaseThresholdFactor: CGFloat = 1.75) {
        self.pixelThreshold = pixelThreshold
        self.releaseThresholdFactor = releaseThresholdFactor
    }

    /// Resets any active snap lock.
    public func reset() {
        currentSnappedTarget = nil
    }

    /// Computes the playhead position considering cue boundaries, timeline endpoints, and hysteresis.
    public func snap(
        rawTime: CMTime,
        cues: [Cue],
        totalDuration: CMTime,
        pixelsPerSecond: Double,
        bypassSnapping: Bool = false
    ) -> SnapResult {
        guard !bypassSnapping, pixelThreshold > 0, pixelsPerSecond > 0, rawTime.isValid, !rawTime.isIndefinite else {
            currentSnappedTarget = nil
            return SnapResult(snappedTime: rawTime, isSnapped: false, snappedTarget: nil, distancePixels: 0)
        }

        let rawSeconds = CMTimeGetSeconds(rawTime)
        let rawPixels = CGFloat(rawSeconds * pixelsPerSecond)
        let releasePixels = pixelThreshold * releaseThresholdFactor

        // Check if currently snapped target remains within release threshold (hysteresis)
        if let snapped = currentSnappedTarget {
            let snappedPixels = CGFloat(CMTimeGetSeconds(snapped) * pixelsPerSecond)
            let delta = abs(rawPixels - snappedPixels)
            if delta <= releasePixels {
                return SnapResult(
                    snappedTime: snapped,
                    isSnapped: true,
                    snappedTarget: snapped,
                    distancePixels: delta
                )
            } else {
                // Break away from lock
                currentSnappedTarget = nil
            }
        }

        // Collect candidate snap targets: cue boundaries + 0 + duration
        var candidates: [CMTime] = [.zero]
        if totalDuration.isValid && !totalDuration.isIndefinite && CMTimeCompare(totalDuration, .zero) > 0 {
            candidates.append(totalDuration)
        }
        for cue in cues {
            candidates.append(cue.start)
            candidates.append(cue.end)
        }

        var closestTarget: CMTime?
        var minDelta: CGFloat = .greatestFiniteMagnitude

        for target in candidates {
            guard target.isValid && !target.isIndefinite else { continue }
            let targetPixels = CGFloat(CMTimeGetSeconds(target) * pixelsPerSecond)
            let delta = abs(rawPixels - targetPixels)
            if delta < minDelta {
                minDelta = delta
                closestTarget = target
            }
        }

        if minDelta <= pixelThreshold, let target = closestTarget {
            currentSnappedTarget = target
            return SnapResult(
                snappedTime: target,
                isSnapped: true,
                snappedTarget: target,
                distancePixels: minDelta
            )
        }

        currentSnappedTarget = nil
        return SnapResult(
            snappedTime: rawTime,
            isSnapped: false,
            snappedTarget: nil,
            distancePixels: minDelta
        )
    }
}
