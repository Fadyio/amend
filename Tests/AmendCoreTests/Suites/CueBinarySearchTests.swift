import Testing
import CoreMedia
import Foundation
@testable import AmendCore

@Suite("Cue Binary Search & Active Highlighting Tests")
struct CueBinarySearchTests {

    private func makeCues() -> [Cue] {
        [
            Cue(timeRange: CMTimeRange(start: CMTime(seconds: 1.0, preferredTimescale: 60000), duration: CMTime(seconds: 1.0, preferredTimescale: 60000)), text: "One"),   // [1.0, 2.0)
            Cue(timeRange: CMTimeRange(start: CMTime(seconds: 2.0, preferredTimescale: 60000), duration: CMTime(seconds: 1.5, preferredTimescale: 60000)), text: "Two"),   // [2.0, 3.5)
            // Silence gap: 3.5 to 5.0
            Cue(timeRange: CMTimeRange(start: CMTime(seconds: 5.0, preferredTimescale: 60000), duration: CMTime(seconds: 2.0, preferredTimescale: 60000)), text: "Three") // [5.0, 7.0)
        ]
    }

    @Test("Binary search accurately identifies cue containing timestamp")
    func test_binary_search_inside_cue() {
        let cues = makeCues()
        let hitTime = CMTime(seconds: 2.75, preferredTimescale: 60000)
        let found = cues.cue(at: hitTime)

        #expect(found != nil)
        #expect(found?.text == "Two")
    }

    @Test("Binary search returns nil during silence gap")
    func test_binary_search_in_silence_gap() {
        let cues = makeCues()
        let gapTime = CMTime(seconds: 4.2, preferredTimescale: 60000)
        #expect(cues.cue(at: gapTime) == nil)
    }

    @Test("Binary search respects half-open interval [start, end)")
    func test_binary_search_boundary_conditions() {
        let cues = makeCues()
        // Exact start of Cue "Two"
        let startTime = CMTime(seconds: 2.0, preferredTimescale: 60000)
        #expect(cues.cue(at: startTime)?.text == "Two")

        // Exact end of Cue "Two" (which is start of silence gap)
        let endTime = CMTime(seconds: 3.5, preferredTimescale: 60000)
        #expect(cues.cue(at: endTime) == nil)

        // Timestamp before first cue
        let beforeTime = CMTime(seconds: 0.5, preferredTimescale: 60000)
        #expect(cues.cue(at: beforeTime) == nil)

        // Timestamp after last cue
        let afterTime = CMTime(seconds: 7.5, preferredTimescale: 60000)
        #expect(cues.cue(at: afterTime) == nil)
    }

    @Test("Window intersection finds all overlapping cues")
    func test_intersecting_cue_range() {
        let cues = makeCues()
        let windowStart = CMTime(seconds: 1.5, preferredTimescale: 60000)
        let windowEnd = CMTime(seconds: 5.5, preferredTimescale: 60000)

        guard let range = cues.cueIndexRange(intersecting: windowStart, endTime: windowEnd) else {
            Issue.record("Expected intersecting range")
            return
        }

        #expect(range == 0..<3)
        let slice = cues[range]
        #expect(slice.count == 3)
    }

    @Test("Window intersection returns single cue when window covers only one")
    func test_intersecting_cue_range_single() {
        let cues = makeCues()
        let windowStart = CMTime(seconds: 2.2, preferredTimescale: 60000)
        let windowEnd = CMTime(seconds: 3.0, preferredTimescale: 60000)

        guard let range = cues.cueIndexRange(intersecting: windowStart, endTime: windowEnd) else {
            Issue.record("Expected intersecting range")
            return
        }

        #expect(range == 1..<2)
        #expect(cues[range.lowerBound].text == "Two")
    }

    @Test("Window intersection in silence gap returns nil")
    func test_intersecting_cue_range_in_silence_gap() {
        let cues = makeCues()
        let windowStart = CMTime(seconds: 3.6, preferredTimescale: 60000)
        let windowEnd = CMTime(seconds: 4.8, preferredTimescale: 60000)

        let range = cues.cueIndexRange(intersecting: windowStart, endTime: windowEnd)
        #expect(range == nil)
    }

    @Test("Large dataset binary search performance and accuracy")
    func test_large_dataset_binary_search() {
        // Create 1000 sequential cues of 0.5s each with 0.1s silence between them
        var largeCues: [Cue] = []
        largeCues.reserveCapacity(1000)
        var currentTime = 0.0

        for i in 0..<1000 {
            let start = CMTime(seconds: currentTime, preferredTimescale: 60000)
            let dur = CMTime(seconds: 0.5, preferredTimescale: 60000)
            largeCues.append(Cue(timeRange: CMTimeRange(start: start, duration: dur), text: "Word_\(i)"))
            currentTime += 0.6 // 0.5s cue + 0.1s gap
        }

        // Test random access across the 1000 cues
        for i in stride(from: 0, to: 1000, by: 47) {
            let midTime = CMTime(seconds: Double(i) * 0.6 + 0.25, preferredTimescale: 60000)
            let found = largeCues.cue(at: midTime)
            #expect(found?.text == "Word_\(i)")

            let gapTime = CMTime(seconds: Double(i) * 0.6 + 0.55, preferredTimescale: 60000)
            #expect(largeCues.cue(at: gapTime) == nil)
        }
    }

    @Test("Empty cues array returns nil gracefully")
    func test_empty_cues_array() {
        let empty: [Cue] = []
        #expect(empty.cue(at: CMTime(seconds: 1.0, preferredTimescale: 60000)) == nil)
        #expect(empty.indexOfCue(at: CMTime(seconds: 1.0, preferredTimescale: 60000)) == nil)
        #expect(empty.cueIndexRange(intersecting: .zero, endTime: CMTime(seconds: 10.0, preferredTimescale: 60000)) == nil)
    }
}
