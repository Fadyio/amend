import Testing
import Foundation
import CoreMedia
@testable import MacDubCore

@Suite("Cue Splitter Tests")
final class CueSplitterTests {
    private let splitter = CueSplitter(minimumDuration: CMTime(value: 10, timescale: 1000)) // 10ms min

    private func makeSampleCues() -> [Cue] {
        [
            Cue(
                timeRange: CMTimeRange(start: CMTime(value: 0, timescale: 1000), duration: CMTime(value: 2000, timescale: 1000)), // 0.0 - 2.0s
                text: "First cue text",
                originalText: "First cue text"
            ),
            Cue(
                timeRange: CMTimeRange(start: CMTime(value: 2000, timescale: 1000), duration: CMTime(value: 3000, timescale: 1000)), // 2.0 - 5.0s
                text: "The quick brown fox jumps over the lazy dog",
                originalText: "The quick brown fox jumps over the lazy dog"
            ),
            Cue(
                timeRange: CMTimeRange(start: CMTime(value: 5000, timescale: 1000), duration: CMTime(value: 4000, timescale: 1000)), // 5.0 - 9.0s
                text: "Third cue text",
                originalText: "Third cue text"
            )
        ]
    }

    @Test("Cue split produces exact zero gap and zero overlap")
    func test_split_zero_gap_and_zero_overlap() throws {
        let initialCues = makeSampleCues()
        let target = initialCues[1]
        let splitTime = CMTime(value: 3500, timescale: 1000) // 3.5s

        let (newCues, cueA, cueB) = try splitter.splitCue(
            in: initialCues,
            targetCueID: target.id,
            at: splitTime
        )

        // 1. Boundary correctness
        #expect(CMTimeCompare(cueA.start, target.start) == 0)
        #expect(CMTimeCompare(cueA.end, splitTime) == 0)
        #expect(CMTimeCompare(cueB.start, splitTime) == 0)
        #expect(CMTimeCompare(cueB.end, target.end) == 0)

        // 2. Zero gap
        let gap = CMTimeSubtract(cueB.start, cueA.end)
        #expect(CMTimeCompare(gap, .zero) == 0)

        // 3. Zero overlap
        #expect(CMTimeCompare(cueA.end, cueB.start) == 0)

        // 4. Combined duration equals original duration
        let combined = CMTimeAdd(cueA.duration, cueB.duration)
        #expect(CMTimeCompare(combined, target.duration) == 0)

        // 5. Total count is original count + 1
        #expect(newCues.count == initialCues.count + 1)

        // 6. Neighboring cues are completely untouched
        #expect(newCues[0] == initialCues[0])
        #expect(newCues[3] == initialCues[2])
    }

    @Test("Cue split with explicit text split index")
    func test_split_with_explicit_text_index() throws {
        let cue = Cue(
            timeRange: CMTimeRange(start: CMTime(value: 1000, timescale: 1000), duration: CMTime(value: 2000, timescale: 1000)),
            text: "Hello World",
            originalText: "Hello World"
        )
        let splitTime = CMTime(value: 2000, timescale: 1000)
        let spaceIndex = cue.text.firstIndex(of: " ")!

        let (cueA, cueB) = try splitter.split(cue: cue, at: splitTime, textSplitIndex: spaceIndex)

        #expect(cueA.text == "Hello")
        #expect(cueB.text == "World")
    }

    @Test("Cue split rejects splitTime before start")
    func test_split_rejects_time_before_start() {
        let cue = Cue(
            timeRange: CMTimeRange(start: CMTime(value: 2000, timescale: 1000), duration: CMTime(value: 3000, timescale: 1000)),
            text: "Testing"
        )

        let outOfBoundsTime = CMTime(value: 1500, timescale: 1000)
        #expect(throws: CueSplitterError.self) {
            try splitter.split(cue: cue, at: outOfBoundsTime)
        }
    }

    @Test("Cue split rejects splitTime after end")
    func test_split_rejects_time_after_end() {
        let cue = Cue(
            timeRange: CMTimeRange(start: CMTime(value: 2000, timescale: 1000), duration: CMTime(value: 3000, timescale: 1000)),
            text: "Testing"
        )

        let outOfBoundsTime = CMTime(value: 5500, timescale: 1000)
        #expect(throws: CueSplitterError.self) {
            try splitter.split(cue: cue, at: outOfBoundsTime)
        }
    }

    @Test("Cue split rejects splitTime exactly at boundary")
    func test_split_rejects_time_at_boundary() {
        let cue = Cue(
            timeRange: CMTimeRange(start: CMTime(value: 2000, timescale: 1000), duration: CMTime(value: 3000, timescale: 1000)),
            text: "Testing"
        )

        #expect(throws: CueSplitterError.self) {
            try splitter.split(cue: cue, at: cue.start)
        }
        #expect(throws: CueSplitterError.self) {
            try splitter.split(cue: cue, at: cue.end)
        }
    }

    @Test("Cue split rejects duration below minimum threshold")
    func test_split_rejects_too_short_duration() {
        let cue = Cue(
            timeRange: CMTimeRange(start: CMTime(value: 2000, timescale: 1000), duration: CMTime(value: 1000, timescale: 1000)),
            text: "Testing"
        )
        // Split only 5ms from start (min threshold is 10ms)
        let tooCloseTime = CMTime(value: 2005, timescale: 1000)

        #expect(throws: CueSplitterError.self) {
            try splitter.split(cue: cue, at: tooCloseTime)
        }
    }

    @Test("Cue split rejects non-existent cue ID in timeline")
    func test_split_rejects_nonexistent_cue_id() {
        let initialCues = makeSampleCues()
        let fakeID = UUID()

        #expect(throws: CueSplitterError.self) {
            try splitter.splitCue(in: initialCues, targetCueID: fakeID, at: CMTime(value: 3000, timescale: 1000))
        }
    }
}
