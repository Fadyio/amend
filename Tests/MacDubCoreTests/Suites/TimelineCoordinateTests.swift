import Testing
import CoreMedia
import Foundation
@testable import MacDubCore

@Suite("Timeline Coordinate & Zoom Tests")
struct TimelineCoordinateTests {

    @Test("Coordinate conversion round-trip preserves exact timestamp")
    func test_coordinate_roundtrip() {
        let converter = TimelineCoordinateConverter(pixelsPerSecond: 100.0, timescale: 60000)
        let originalTime = CMTime(value: 123450, timescale: 60000) // 2.0575 seconds

        let x = converter.timeToX(originalTime)
        #expect(abs(x - 205.75) < 1e-6)

        let restoredTime = converter.xToTime(x)
        #expect(CMTimeCompare(originalTime, restoredTime) == 0)
    }

    @Test("Zoom limits clamp strictly within 10 to 1000 px/sec")
    func test_zoom_clamping() {
        let minConverter = TimelineCoordinateConverter(pixelsPerSecond: 2.0)
        #expect(minConverter.pixelsPerSecond == 10.0)

        let maxConverter = TimelineCoordinateConverter(pixelsPerSecond: 5000.0)
        #expect(maxConverter.pixelsPerSecond == 1000.0)

        let midConverter = TimelineCoordinateConverter(pixelsPerSecond: 250.0)
        #expect(midConverter.pixelsPerSecond == 250.0)
    }

    @Test("Zero-gap cue layout invariant: Adjacent cues share exact boundary point")
    func test_zero_gap_boundary_continuity() {
        let converter = TimelineCoordinateConverter(pixelsPerSecond: 150.0)
        let splitTime = CMTime(seconds: 4.3125, preferredTimescale: 60000)
        let range1 = CMTimeRange(start: .zero, end: splitTime)
        let range2 = CMTimeRange(start: splitTime, duration: CMTime(seconds: 2.5, preferredTimescale: 60000))

        let rect1 = converter.timeRangeToRect(range1, height: 48)
        let rect2 = converter.timeRangeToRect(range2, height: 48)

        #expect(abs(rect1.maxX - rect2.minX) < 1e-9)
        #expect(rect1.origin.x == 0.0)
        #expect(abs(rect1.width - (4.3125 * 150.0)) < 1e-6)
    }

    @Test("Anchor-preserving zoom maintains exact viewport timestamp position")
    func test_anchor_preserved_zoom() {
        let totalDuration = CMTime(seconds: 60.0, preferredTimescale: 60000)
        let oldPPS = 50.0
        let newPPS = 200.0
        let currentOffset = 100.0 // Scrolled 2.0 seconds into timeline
        let anchorViewportX = 400.0 // Anchor is 400pt from left of window (8.0s in viewport; total timestamp = 10.0s)

        // Time under anchor before zoom: (100 + 400) / 50 = 10.0 seconds
        let newOffset = TimelineCoordinateConverter.preservedScrollOffset(
            currentOffset: currentOffset,
            oldPPS: oldPPS,
            newPPS: newPPS,
            anchorViewportX: anchorViewportX,
            totalDuration: totalDuration,
            viewportWidth: 1000.0
        )

        // Time under anchor after zoom: (newOffset + 400) / 200 must equal 10.0 seconds
        let timeAfterZoom = (newOffset + anchorViewportX) / newPPS
        #expect(abs(timeAfterZoom - 10.0) < 1e-6)
    }

    @Test("Anchor-preserving zoom clamps within valid scroll bounds")
    func test_anchor_preserved_zoom_clamping() {
        let totalDuration = CMTime(seconds: 10.0, preferredTimescale: 60000)
        let viewportWidth = 1000.0

        // Zoom out to overview where content width (10.0 * 20 = 200) < viewportWidth (1000)
        let offset = TimelineCoordinateConverter.preservedScrollOffset(
            currentOffset: 50.0,
            oldPPS: 50.0,
            newPPS: 20.0,
            anchorViewportX: 500.0,
            totalDuration: totalDuration,
            viewportWidth: viewportWidth
        )
        #expect(offset == 0.0)
    }

    @Test("Logarithmic zoom slider scale roundtrip")
    func test_logarithmic_slider_scale_roundtrip() {
        // 10.0 px/s maps to 0.0
        #expect(abs(TimelineCoordinateConverter.normalizedScale(fromPPS: 10.0) - 0.0) < 1e-9)
        #expect(abs(TimelineCoordinateConverter.pps(fromNormalizedScale: 0.0) - 10.0) < 1e-9)

        // 100.0 px/s maps to 0.5
        #expect(abs(TimelineCoordinateConverter.normalizedScale(fromPPS: 100.0) - 0.5) < 1e-9)
        #expect(abs(TimelineCoordinateConverter.pps(fromNormalizedScale: 0.5) - 100.0) < 1e-9)

        // 1000.0 px/s maps to 1.0
        #expect(abs(TimelineCoordinateConverter.normalizedScale(fromPPS: 1000.0) - 1.0) < 1e-9)
        #expect(abs(TimelineCoordinateConverter.pps(fromNormalizedScale: 1.0) - 1000.0) < 1e-9)

        // Arbitrary PPS round-trip
        let testPPS = 345.67
        let norm = TimelineCoordinateConverter.normalizedScale(fromPPS: testPPS)
        let restored = TimelineCoordinateConverter.pps(fromNormalizedScale: norm)
        #expect(abs(testPPS - restored) < 1e-6)
    }

    @Test("Invalid and negative CMTime handling in coordinate converter")
    func test_invalid_and_negative_time() {
        let converter = TimelineCoordinateConverter(pixelsPerSecond: 100.0)

        #expect(converter.timeToX(.invalid) == 0.0)
        #expect(converter.timeToX(.indefinite) == 0.0)

        let negativeTime = CMTime(seconds: -5.0, preferredTimescale: 60000)
        #expect(converter.timeToX(negativeTime) == 0.0)

        let negativeX = converter.xToTime(-50.0)
        #expect(CMTimeCompare(negativeX, .zero) == 0)
    }
}
