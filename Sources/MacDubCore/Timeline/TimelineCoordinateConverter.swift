import Foundation
import CoreMedia
import CoreGraphics

/// Provides high-precision coordinate transformations between continuous Core Media time (`CMTime`)
/// and horizontal display pixel coordinates across zoom levels.
public struct TimelineCoordinateConverter: Sendable {
    public let pixelsPerSecond: Double
    public let timescale: CMTimeScale

    public init(pixelsPerSecond: Double, timescale: CMTimeScale = 60000) {
        self.pixelsPerSecond = max(10.0, min(1000.0, pixelsPerSecond))
        self.timescale = timescale
    }

    /// Converts a continuous timestamp to a horizontal pixel coordinate.
    @inlinable
    public func timeToX(_ time: CMTime) -> Double {
        guard time.isValid && !time.isIndefinite else { return 0.0 }
        let seconds = CMTimeGetSeconds(time)
        return max(0.0, seconds * pixelsPerSecond)
    }

    /// Converts a horizontal pixel coordinate back to a continuous `CMTime` without frame rounding.
    @inlinable
    public func xToTime(_ x: Double) -> CMTime {
        guard pixelsPerSecond > 0 else { return .zero }
        let clampedX = max(0.0, x)
        let seconds = clampedX / pixelsPerSecond
        return CMTime(seconds: seconds, preferredTimescale: timescale)
    }

    /// Converts a `CMTimeRange` to a layout rectangle guaranteeing exact zero-gap alignment between adjacent cues.
    @inlinable
    public func timeRangeToRect(_ range: CMTimeRange, height: Double, y: Double = 0.0) -> CGRect {
        let startX = timeToX(range.start)
        let endX = timeToX(range.end)
        let width = max(0.0, endX - startX)
        return CGRect(x: startX, y: y, width: width, height: height)
    }

    /// Computes the adjusted scroll offset when zooming, keeping the timestamp under the anchor coordinate stationary.
    public static func preservedScrollOffset(
        currentOffset: Double,
        oldPPS: Double,
        newPPS: Double,
        anchorViewportX: Double,
        totalDuration: CMTime,
        viewportWidth: Double
    ) -> Double {
        guard oldPPS > 0 else { return 0.0 }
        let ratio = newPPS / oldPPS
        let idealOffset = currentOffset * ratio + anchorViewportX * (ratio - 1.0)
        let maxOffset = max(0.0, (CMTimeGetSeconds(totalDuration) * newPPS) - viewportWidth)
        return max(0.0, min(idealOffset, maxOffset))
    }

    /// Maps a pixels-per-second value (10.0 to 1000.0) to a normalized perceptual logarithmic slider scale [0.0, 1.0].
    @inlinable
    public static func normalizedScale(fromPPS pps: Double) -> Double {
        let clamped = max(10.0, min(1000.0, pps))
        return log10(clamped / 10.0) / 2.0
    }

    /// Maps a normalized perceptual logarithmic slider value [0.0, 1.0] back to pixels-per-second (10.0 to 1000.0).
    @inlinable
    public static func pps(fromNormalizedScale scale: Double) -> Double {
        let clamped = max(0.0, min(1.0, scale))
        return 10.0 * pow(10.0, 2.0 * clamped)
    }
}

// MARK: - Binary Search Cue Lookup Extensions

public extension Array where Element == Cue {
    /// Finds the cue containing the given timestamp in O(log N) time.
    /// Returns nil during silence gaps between cues or outside timeline bounds.
    func cue(at time: CMTime) -> Cue? {
        guard let index = indexOfCue(at: time) else { return nil }
        return self[index]
    }

    /// Binary search returning the index of the containing cue in O(log N).
    func indexOfCue(at time: CMTime) -> Int? {
        guard !isEmpty, time.isValid, !time.isIndefinite else { return nil }
        var low = 0
        var high = count - 1

        while low <= high {
            let mid = low + (high - low) / 2
            let candidate = self[mid]

            if CMTimeCompare(time, candidate.timeRange.start) < 0 {
                high = mid - 1
            } else if CMTimeCompare(time, candidate.timeRange.end) >= 0 {
                low = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }

    /// Returns the index range of cues intersecting a visible horizontal window [startTime, endTime] in O(log N).
    func cueIndexRange(intersecting startTime: CMTime, endTime: CMTime) -> Range<Int>? {
        guard !isEmpty, CMTimeCompare(startTime, endTime) <= 0 else { return nil }

        // Binary search for first cue where end > startTime
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if CMTimeCompare(self[mid].timeRange.end, startTime) <= 0 {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let startIndex = low
        guard startIndex < count else { return nil }

        // Binary search for first cue where start >= endTime
        low = startIndex
        high = count
        while low < high {
            let mid = (low + high) / 2
            if CMTimeCompare(self[mid].timeRange.start, endTime) < 0 {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let endIndex = low
        guard startIndex < endIndex else { return nil }
        return startIndex..<endIndex
    }
}
