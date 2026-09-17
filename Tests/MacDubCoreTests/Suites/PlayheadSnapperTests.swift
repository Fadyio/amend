import Testing
import CoreMedia
import Foundation
@testable import MacDubCore

@Suite("Playhead Magnetic Snapper Tests")
struct PlayheadSnapperTests {

    private func makeSampleCues() -> [Cue] {
        [
            Cue(
                timeRange: CMTimeRange(
                    start: CMTime(seconds: 1.0, preferredTimescale: 60000),
                    duration: CMTime(seconds: 2.0, preferredTimescale: 60000)
                ),
                text: "First" // [1.0s, 3.0s)
            ),
            Cue(
                timeRange: CMTimeRange(
                    start: CMTime(seconds: 4.0, preferredTimescale: 60000),
                    duration: CMTime(seconds: 3.0, preferredTimescale: 60000)
                ),
                text: "Second" // [4.0s, 7.0s)
            )
        ]
    }

    @Test("Pixel threshold scales inversely with zoom level")
    func test_pixel_to_time_threshold_scaling() {
        let snapper = PlayheadSnapper(pixelThreshold: 8.0, releaseThresholdFactor: 1.75)
        let cues = makeSampleCues()
        let totalDuration = CMTime(seconds: 10.0, preferredTimescale: 60000)

        // At 100 px/s, 8 px threshold = 0.08s (80ms)
        // Raw time 1.05s is 0.05s (50ms = 5px) from Cue 1 start (1.0s) -> should snap
        let rawTimeNear = CMTime(seconds: 1.05, preferredTimescale: 60000)
        let result100 = snapper.snap(
            rawTime: rawTimeNear,
            cues: cues,
            totalDuration: totalDuration,
            pixelsPerSecond: 100.0
        )
        #expect(result100.isSnapped)
        #expect(CMTimeCompare(result100.snappedTime, CMTime(seconds: 1.0, preferredTimescale: 60000)) == 0)
        #expect(abs(result100.distancePixels - 5.0) < 1e-4)

        snapper.reset()

        // At 1000 px/s, 8 px threshold = 0.008s (8ms)
        // Raw time 1.05s is 50ms (50px) from 1.0s -> should NOT snap
        let result1000 = snapper.snap(
            rawTime: rawTimeNear,
            cues: cues,
            totalDuration: totalDuration,
            pixelsPerSecond: 1000.0
        )
        #expect(!result1000.isSnapped)
        #expect(CMTimeCompare(result1000.snappedTime, rawTimeNear) == 0)
    }

    @Test("Snapping accurately targets cue in-points and out-points")
    func test_cue_boundary_snapping_start_and_end() {
        let snapper = PlayheadSnapper(pixelThreshold: 8.0)
        let cues = makeSampleCues()
        let totalDuration = CMTime(seconds: 10.0, preferredTimescale: 60000)
        let pps = 100.0

        // Near start of Cue 1 (1.0s)
        let nearStart = CMTime(seconds: 0.96, preferredTimescale: 60000) // 4px before 1.0s
        let startResult = snapper.snap(rawTime: nearStart, cues: cues, totalDuration: totalDuration, pixelsPerSecond: pps)
        #expect(startResult.isSnapped)
        #expect(CMTimeCompare(startResult.snappedTime, CMTime(seconds: 1.0, preferredTimescale: 60000)) == 0)
        #expect(abs(startResult.distancePixels - 4.0) < 1e-4)

        snapper.reset()

        // Near end of Cue 1 (3.0s)
        let nearEnd = CMTime(seconds: 3.06, preferredTimescale: 60000) // 6px after 3.0s
        let endResult = snapper.snap(rawTime: nearEnd, cues: cues, totalDuration: totalDuration, pixelsPerSecond: pps)
        #expect(endResult.isSnapped)
        #expect(CMTimeCompare(endResult.snappedTime, CMTime(seconds: 3.0, preferredTimescale: 60000)) == 0)
        #expect(abs(endResult.distancePixels - 6.0) < 1e-4)
    }

    @Test("Snapping accurately targets timeline origin and total duration")
    func test_origin_and_total_duration_snapping() {
        let snapper = PlayheadSnapper(pixelThreshold: 8.0)
        let cues = makeSampleCues()
        let totalDuration = CMTime(seconds: 10.0, preferredTimescale: 60000)
        let pps = 100.0

        // Near timeline origin (0.0s)
        let nearZero = CMTime(seconds: 0.04, preferredTimescale: 60000) // 4px away
        let zeroResult = snapper.snap(rawTime: nearZero, cues: cues, totalDuration: totalDuration, pixelsPerSecond: pps)
        #expect(zeroResult.isSnapped)
        #expect(CMTimeCompare(zeroResult.snappedTime, .zero) == 0)

        snapper.reset()

        // Near total duration (10.0s)
        let nearTotal = CMTime(seconds: 9.95, preferredTimescale: 60000) // 5px before 10.0s
        let totalResult = snapper.snap(rawTime: nearTotal, cues: cues, totalDuration: totalDuration, pixelsPerSecond: pps)
        #expect(totalResult.isSnapped)
        #expect(CMTimeCompare(totalResult.snappedTime, totalDuration) == 0)
    }

    @Test("Nearest target is selected when multiple candidates are within threshold")
    func test_nearest_target_resolution() {
        let snapper = PlayheadSnapper(pixelThreshold: 20.0) // Wide threshold
        // Adjacent cues sharing a boundary at 3.0s, plus another boundary at 3.1s
        let cues = [
            Cue(timeRange: CMTimeRange(start: .zero, end: CMTime(seconds: 3.0, preferredTimescale: 60000)), text: "A"),
            Cue(timeRange: CMTimeRange(start: CMTime(seconds: 3.0, preferredTimescale: 60000), duration: CMTime(seconds: 0.1, preferredTimescale: 60000)), text: "B"),
            Cue(timeRange: CMTimeRange(start: CMTime(seconds: 3.1, preferredTimescale: 60000), duration: CMTime(seconds: 1.0, preferredTimescale: 60000)), text: "C")
        ]
        let totalDuration = CMTime(seconds: 5.0, preferredTimescale: 60000)
        let pps = 100.0

        // Test position at 3.03s (3px from 3.0s, 7px from 3.1s) -> closer to 3.0s
        let result1 = snapper.snap(
            rawTime: CMTime(seconds: 3.03, preferredTimescale: 60000),
            cues: cues,
            totalDuration: totalDuration,
            pixelsPerSecond: pps
        )
        #expect(result1.isSnapped)
        #expect(CMTimeCompare(result1.snappedTime, CMTime(seconds: 3.0, preferredTimescale: 60000)) == 0)

        snapper.reset()

        // Test position at 3.08s (8px from 3.0s, 2px from 3.1s) -> closer to 3.1s
        let result2 = snapper.snap(
            rawTime: CMTime(seconds: 3.08, preferredTimescale: 60000),
            cues: cues,
            totalDuration: totalDuration,
            pixelsPerSecond: pps
        )
        #expect(result2.isSnapped)
        #expect(CMTimeCompare(result2.snappedTime, CMTime(seconds: 3.1, preferredTimescale: 60000)) == 0)
    }

    @Test("Dual-threshold hysteresis locks target until release threshold is exceeded")
    func test_dual_threshold_hysteresis() {
        let snapper = PlayheadSnapper(pixelThreshold: 8.0, releaseThresholdFactor: 1.75) // Acquire: 8px, Release: 14px
        let cues = makeSampleCues() // Cue 1 at 1.0s
        let totalDuration = CMTime(seconds: 10.0, preferredTimescale: 60000)
        let pps = 100.0

        // 1. Enter within acquisition threshold (6px away: 1.06s) -> snaps to 1.0s
        let step1 = snapper.snap(
            rawTime: CMTime(seconds: 1.06, preferredTimescale: 60000),
            cues: cues,
            totalDuration: totalDuration,
            pixelsPerSecond: pps
        )
        #expect(step1.isSnapped)
        #expect(CMTimeCompare(step1.snappedTime, CMTime(seconds: 1.0, preferredTimescale: 60000)) == 0)

        // 2. Drag to 11px away (1.11s).
        // 11px > 8px (acquisition threshold) but <= 14px (release threshold).
        // Because already snapped, hysteresis MUST retain the snap lock!
        let step2 = snapper.snap(
            rawTime: CMTime(seconds: 1.11, preferredTimescale: 60000),
            cues: cues,
            totalDuration: totalDuration,
            pixelsPerSecond: pps
        )
        #expect(step2.isSnapped)
        #expect(CMTimeCompare(step2.snappedTime, CMTime(seconds: 1.0, preferredTimescale: 60000)) == 0)
        #expect(abs(step2.distancePixels - 11.0) < 1e-4)

        // 3. Drag past release threshold to 15px away (1.15s).
        // 15px > 14px -> snap breaks away!
        let step3 = snapper.snap(
            rawTime: CMTime(seconds: 1.15, preferredTimescale: 60000),
            cues: cues,
            totalDuration: totalDuration,
            pixelsPerSecond: pps
        )
        #expect(!step3.isSnapped)
        #expect(CMTimeCompare(step3.snappedTime, CMTime(seconds: 1.15, preferredTimescale: 60000)) == 0)
    }

    @Test("Bypass snapping modifier key completely disables snapping")
    func test_modifier_bypass() {
        let snapper = PlayheadSnapper(pixelThreshold: 8.0)
        let cues = makeSampleCues()
        let totalDuration = CMTime(seconds: 10.0, preferredTimescale: 60000)

        // 1px away from Cue 1 start (1.01s at 100 px/s) with bypassSnapping: true
        let rawTime = CMTime(seconds: 1.01, preferredTimescale: 60000)
        let result = snapper.snap(
            rawTime: rawTime,
            cues: cues,
            totalDuration: totalDuration,
            pixelsPerSecond: 100.0,
            bypassSnapping: true
        )
        #expect(!result.isSnapped)
        #expect(result.snappedTarget == nil)
        #expect(CMTimeCompare(result.snappedTime, rawTime) == 0)
    }

    @Test("Reset clears active hysteresis snap target")
    func test_reset_clears_snap_lock() {
        let snapper = PlayheadSnapper(pixelThreshold: 8.0, releaseThresholdFactor: 1.75)
        let cues = makeSampleCues()
        let totalDuration = CMTime(seconds: 10.0, preferredTimescale: 60000)
        let pps = 100.0

        // Acquire snap at 1.05s (5px away)
        _ = snapper.snap(rawTime: CMTime(seconds: 1.05, preferredTimescale: 60000), cues: cues, totalDuration: totalDuration, pixelsPerSecond: pps)

        // Reset snapper
        snapper.reset()

        // Probe at 1.10s (10px away).
        // Without reset, 10px <= 14px release would hold snap.
        // With reset, 10px > 8px acquisition, so it must NOT snap.
        let result = snapper.snap(
            rawTime: CMTime(seconds: 1.10, preferredTimescale: 60000),
            cues: cues,
            totalDuration: totalDuration,
            pixelsPerSecond: pps
        )
        #expect(!result.isSnapped)
    }

    @Test("Zero or negative parameters gracefully disable snapping")
    func test_zero_or_negative_parameters() {
        let zeroThresholdSnapper = PlayheadSnapper(pixelThreshold: 0)
        let cues = makeSampleCues()
        let totalDuration = CMTime(seconds: 10.0, preferredTimescale: 60000)
        let rawTime = CMTime(seconds: 1.01, preferredTimescale: 60000)

        let resultZero = zeroThresholdSnapper.snap(rawTime: rawTime, cues: cues, totalDuration: totalDuration, pixelsPerSecond: 100.0)
        #expect(!resultZero.isSnapped)

        let normalSnapper = PlayheadSnapper(pixelThreshold: 8.0)
        let resultZeroPPS = normalSnapper.snap(rawTime: rawTime, cues: cues, totalDuration: totalDuration, pixelsPerSecond: 0.0)
        #expect(!resultZeroPPS.isSnapped)
    }

    @Test("Invalid and indefinite timestamps return unsnapped without errors")
    func test_invalid_and_indefinite_time() {
        let snapper = PlayheadSnapper(pixelThreshold: 8.0)
        let cues = makeSampleCues()
        let totalDuration = CMTime(seconds: 10.0, preferredTimescale: 60000)

        let invalidResult = snapper.snap(rawTime: .invalid, cues: cues, totalDuration: totalDuration, pixelsPerSecond: 100.0)
        #expect(!invalidResult.isSnapped)

        let indefiniteResult = snapper.snap(rawTime: .indefinite, cues: cues, totalDuration: totalDuration, pixelsPerSecond: 100.0)
        #expect(!indefiniteResult.isSnapped)
    }

    @Test("Performance across 500 cues remains instantaneous")
    func test_large_cue_count_performance() {
        let snapper = PlayheadSnapper(pixelThreshold: 8.0)
        var cues: [Cue] = []
        cues.reserveCapacity(500)
        for i in 0..<500 {
            let start = CMTime(seconds: Double(i) * 2.0, preferredTimescale: 60000)
            let dur = CMTime(seconds: 1.5, preferredTimescale: 60000)
            cues.append(Cue(timeRange: CMTimeRange(start: start, duration: dur), text: "Word\(i)"))
        }
        let totalDuration = CMTime(seconds: 1000.0, preferredTimescale: 60000)

        // Perform 100 snap evaluations
        let startClock = CFAbsoluteTimeGetCurrent()
        for i in 0..<100 {
            let probe = CMTime(seconds: Double(i) * 5.0 + 0.03, preferredTimescale: 60000)
            _ = snapper.snap(rawTime: probe, cues: cues, totalDuration: totalDuration, pixelsPerSecond: 100.0)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - startClock
        // 100 snaps over 500 cues should comfortably execute in < 100ms
        #expect(elapsed < 0.1)
    }
}
