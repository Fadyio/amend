import Testing
import CoreMedia
import Foundation
@testable import AmendCore
import SwiftTimecodeCore

@Suite("SMPTE Ruler Formatter Tests")
struct SMPTERulerFormatterTests {

    @Test("Non-drop frame rates format correctly with colon separator")
    func test_non_drop_frame_formatting() {
        let formatter30 = SMPTERulerFormatter(frameRate: .fps30)

        #expect(formatter30.string(from: .zero) == "00:00:00:00")
        #expect(formatter30.string(from: CMTime(seconds: 1.0, preferredTimescale: 60000)) == "00:00:01:00")
        #expect(formatter30.string(from: CMTime(seconds: 1.5, preferredTimescale: 60000)) == "00:00:01:15")
        #expect(formatter30.string(from: CMTime(seconds: 62.0, preferredTimescale: 60000)) == "00:01:02:00")

        let formatter24 = SMPTERulerFormatter(frameRate: .fps24)
        #expect(formatter24.string(from: CMTime(seconds: 1.5, preferredTimescale: 60000)) == "00:00:01:12")

        let formatter60 = SMPTERulerFormatter(frameRate: .fps60)
        #expect(formatter60.string(from: CMTime(seconds: 0.5, preferredTimescale: 60000)) == "00:00:00:30")
    }

    @Test("Drop frame rates format with semicolon separator")
    func test_drop_frame_separator() {
        let formatter2997d = SMPTERulerFormatter(frameRate: .fps29_97d)
        let formatted = formatter2997d.string(from: CMTime(seconds: 2.0, preferredTimescale: 60000))
        #expect(formatted.contains(";"), "Drop frame timecode must contain semicolon separator")

        let formatter5994d = SMPTERulerFormatter(frameRate: .fps59_94d)
        let formatted5994 = formatter5994d.string(from: CMTime(seconds: 2.0, preferredTimescale: 60000))
        #expect(formatted5994.contains(";"), "Drop frame 59.94d must contain semicolon separator")
    }

    @Test("Drop frame math drops frames 00 and 01 on non-decade minutes at 29.97 DF")
    func test_drop_frame_dropped_frames_behavior() throws {
        // At 29.97d, minute 1 drops frames 00 and 01.
        // Therefore, the frame after 00:00:59;29 is 00:01:00;02!
        let tcBeforeMinute1 = try Timecode(.string("00:00:59;29"), at: .fps29_97d)
        let tcMinute1 = try tcBeforeMinute1.adding(.frames(1))
        #expect(tcMinute1.stringValue() == "00:01:00;02", "Minute 1 must drop frames 00 and 01 to advance to 00:01:00;02")

        // Multiples of 10 (decade minutes) do NOT drop frames.
        // Therefore, the frame after 00:09:59;29 is 00:10:00;00!
        let tcBeforeMinute10 = try Timecode(.string("00:09:59;29"), at: .fps29_97d)
        let tcMinute10 = try tcBeforeMinute10.adding(.frames(1))
        #expect(tcMinute10.stringValue() == "00:10:00;00", "Minute 10 must NOT drop frames and advance to 00:10:00;00")

        // Attempting to construct dropped frames directly in non-decade minute throws an invalid timecode error
        #expect(throws: Error.self) {
            try Timecode(.string("00:01:00;00"), at: .fps29_97d)
        }
        #expect(throws: Error.self) {
            try Timecode(.string("00:01:00;01"), at: .fps29_97d)
        }
    }

    @Test("Subframes display option formats with subframe component")
    func test_subframes_formatting() {
        let formatter = SMPTERulerFormatter(frameRate: .fps30)
        let subframeTime = CMTime(value: 1005, timescale: 600) // 1.675s = 1s + 20 frames + 0.25 frame
        let withSub = formatter.string(from: subframeTime, includeSubFrames: true)
        let withoutSub = formatter.string(from: subframeTime, includeSubFrames: false)

        #expect(withSub != withoutSub)
        #expect(withSub.count > withoutSub.count)
    }

    @Test("Bidirectional roundtrip from CMTime to string and back to CMTime")
    func test_bidirectional_roundtrip() throws {
        let frameRates: [TimecodeFrameRate] = [
            .fps23_976, .fps24, .fps25, .fps29_97, .fps29_97d, .fps30, .fps59_94, .fps59_94d, .fps60
        ]

        let testSeconds: [Double] = [0.0, 1.25, 15.6, 62.33, 125.5]

        for rate in frameRates {
            let formatter = SMPTERulerFormatter(frameRate: rate)
            let frameDuration = 1.0 / rate.realTimeFPS

            for sec in testSeconds {
                let originalTime = CMTime(seconds: sec, preferredTimescale: 600_000)
                let str = formatter.string(from: originalTime)
                let parsedTime = try formatter.time(from: str)

                let delta = abs(CMTimeGetSeconds(originalTime) - CMTimeGetSeconds(parsedTime))
                // Error must be strictly less than one full frame duration
                #expect(delta <= frameDuration + 0.001, "Delta \(delta) must be <= frameDuration \(frameDuration) for \(rate)")
            }
        }
    }

    @Test("Major interval ladder adapts dynamically to zoom level")
    func test_major_interval_ladder() {
        let formatter = SMPTERulerFormatter(frameRate: .fps30)

        // At 10 px/s (overview zoom): target spacing 100px -> ideal interval 10s
        let intervalOverview = formatter.majorInterval(for: 10.0, targetPixelSpacing: 100.0)
        #expect(intervalOverview >= 10.0)

        // At 100 px/s (default zoom): target spacing 100px -> ideal interval 1s
        let intervalDefault = formatter.majorInterval(for: 100.0, targetPixelSpacing: 100.0)
        #expect(intervalDefault == 1.0)

        // At 1000 px/s (detailed zoom): target spacing 100px -> ideal interval 0.1s
        let intervalDetail = formatter.majorInterval(for: 1000.0, targetPixelSpacing: 100.0)
        #expect(intervalDetail <= 0.5)
    }

    @Test("Viewport culling generates only visible ticks with minor subdivisions")
    func test_viewport_culling_and_tick_generation() {
        let formatter = SMPTERulerFormatter(frameRate: .fps30)
        let totalDuration = CMTime(seconds: 60.0, preferredTimescale: 600_000)
        let pps = 100.0 // 1s = 100px

        // Viewport covering 2.0s to 5.0s (x in 200...500)
        let visibleRect = CGRect(x: 200, y: 0, width: 300, height: 24)
        let ticks = formatter.generateTicks(
            visibleRect: visibleRect,
            pixelsPerSecond: pps,
            totalDuration: totalDuration
        )

        #expect(!ticks.isEmpty)

        // Major ticks should have non-nil labels; minor ticks should have nil labels
        let majorTicks = ticks.filter { $0.isMajor }
        let minorTicks = ticks.filter { !$0.isMajor }

        #expect(!majorTicks.isEmpty)
        for major in majorTicks {
            #expect(major.label != nil)
            #expect(major.pixelOffset >= 150.0 && major.pixelOffset <= 550.0)
        }

        for minor in minorTicks {
            #expect(minor.label == nil)
        }

        // Ticks far outside viewport (e.g. at 50 seconds = 5000px) must NOT be generated
        #expect(!ticks.contains { $0.pixelOffset > 600.0 })
        #expect(!ticks.contains { $0.pixelOffset < 150.0 })
    }

    @Test("Invalid and edge case inputs return safe defaults")
    func test_invalid_and_edge_case_inputs() {
        let formatter = SMPTERulerFormatter(frameRate: .fps30)

        #expect(formatter.string(from: .invalid) == "00:00:00:00")
        #expect(formatter.string(from: .indefinite) == "00:00:00:00")

        let emptyTicks = formatter.generateTicks(
            visibleRect: CGRect(x: 0, y: 0, width: 500, height: 24),
            pixelsPerSecond: 0,
            totalDuration: CMTime(seconds: 10.0, preferredTimescale: 600)
        )
        #expect(emptyTicks.isEmpty)

        let zeroDurationTicks = formatter.generateTicks(
            visibleRect: CGRect(x: 0, y: 0, width: 500, height: 24),
            pixelsPerSecond: 100.0,
            totalDuration: .zero
        )
        #expect(zeroDurationTicks.count <= 1)

        #expect(throws: Error.self) {
            try formatter.time(from: "invalid-timecode")
        }
    }
}
