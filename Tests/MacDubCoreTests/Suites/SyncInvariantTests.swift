import Testing
import Foundation
import CoreMedia
@testable import MacDubCore

@Suite("Sync Invariant Tests")
final class SyncInvariantTests {
    private let engine = SyncInvariantEngine()

    private func makeSampleCues() -> [Cue] {
        [
            Cue(
                timeRange: CMTimeRange(start: CMTime(value: 0, timescale: 48000), duration: CMTime(value: 96000, timescale: 48000)), // 0.0 - 2.0s
                text: "First cue text",
                originalText: "First cue text"
            ),
            Cue(
                timeRange: CMTimeRange(start: CMTime(value: 96000, timescale: 48000), duration: CMTime(value: 144000, timescale: 48000)), // 2.0 - 5.0s
                text: "Second cue text to be edited",
                originalText: "Second cue text to be edited"
            ),
            Cue(
                timeRange: CMTimeRange(start: CMTime(value: 240000, timescale: 48000), duration: CMTime(value: 240000, timescale: 48000)), // 5.0 - 10.0s
                text: "Third cue text that must remain immutable",
                originalText: "Third cue text that must remain immutable"
            )
        ]
    }

    @Test("Modifying text of Cue N leaves Cue N+1 boundaries strictly immutable")
    func test_cue_text_edit_leaves_adjacent_boundaries_identical() throws {
        let initialCues = makeSampleCues()
        let targetCueID = initialCues[1].id
        let nextCueBefore = initialCues[2]

        let updatedCues = try engine.updateCueText(
            in: initialCues,
            cueID: targetCueID,
            newText: "Completely revised narration that is much longer or shorter."
        )

        let nextCueAfter = updatedCues[2]

        // Acceptance Criteria 114: Cue[N+1] start and end remain identical
        #expect(CMTimeCompare(nextCueAfter.start, nextCueBefore.start) == 0)
        #expect(CMTimeCompare(nextCueAfter.duration, nextCueBefore.duration) == 0)
        #expect(CMTimeCompare(nextCueAfter.end, nextCueBefore.end) == 0)

        // Exact rational equality
        #expect(nextCueAfter.timeRange.start.value == nextCueBefore.timeRange.start.value)
        #expect(nextCueAfter.timeRange.start.timescale == nextCueBefore.timeRange.start.timescale)
        #expect(nextCueAfter.timeRange.duration.value == nextCueBefore.timeRange.duration.value)
        #expect(nextCueAfter.timeRange.duration.timescale == nextCueBefore.timeRange.duration.timescale)
    }

    @Test("Replacing audio of Cue N preserves immutable slot timeRange")
    func test_cue_audio_replacement_preserves_slot_boundaries() throws {
        let initialCues = makeSampleCues()
        let targetCueID = initialCues[0].id
        let nextCueBefore = initialCues[1]

        let updatedCues = try engine.updateCueAudio(
            in: initialCues,
            cueID: targetCueID,
            audioRelativePath: "cues/synthesized_cue_0.wav",
            editState: .synthesized,
            overflowDelta: nil
        )

        let targetAfter = updatedCues[0]
        let nextAfter = updatedCues[1]

        #expect(CMTimeCompare(targetAfter.start, initialCues[0].start) == 0)
        #expect(CMTimeCompare(targetAfter.duration, initialCues[0].duration) == 0)
        #expect(targetAfter.audioWAVRelativePath == "cues/synthesized_cue_0.wav")
        #expect(targetAfter.editState == .synthesized)

        #expect(CMTimeCompare(nextAfter.start, nextCueBefore.start) == 0)
        #expect(CMTimeCompare(nextAfter.duration, nextCueBefore.duration) == 0)
    }

    @Test("Sync invariant rejects non-target cue mutations")
    func test_invariant_rejects_non_target_mutation() {
        let initialCues = makeSampleCues()
        var mutatedCues = initialCues
        // Mutate non-target cue text
        mutatedCues[0] = mutatedCues[0].withUpdatedText("Unauthorized sneaky change")

        #expect(throws: SyncInvariantError.self) {
            try engine.assertSyncInvariant(before: initialCues, after: mutatedCues, modifiedCueID: initialCues[1].id)
        }
    }

    @Test("Sync invariant rejects boundary shifts in target cue")
    func test_invariant_rejects_target_boundary_shift() {
        let initialCues = makeSampleCues()
        var shiftedCues = initialCues
        let shiftedRange = CMTimeRange(
            start: CMTime(value: 96001, timescale: 48000), // 1 tick shift!
            duration: initialCues[1].duration
        )
        shiftedCues[1] = Cue(
            id: initialCues[1].id,
            timeRange: shiftedRange,
            text: "Shifted",
            originalText: initialCues[1].originalText
        )

        #expect(throws: SyncInvariantError.self) {
            try engine.assertSyncInvariant(before: initialCues, after: shiftedCues, modifiedCueID: initialCues[1].id)
        }
    }

    @Test("Timeline continuity validates chronological non-overlapping cues")
    func test_timeline_continuity_valid() throws {
        let cues = makeSampleCues()
        try engine.validateTimelineContinuity(cues: cues, totalDuration: CMTime(value: 480000, timescale: 48000))
    }

    @Test("Timeline continuity rejects overlapping cues")
    func test_timeline_continuity_rejects_overlaps() {
        let overlappingCues = [
            Cue(
                timeRange: CMTimeRange(start: CMTime(value: 0, timescale: 10), duration: CMTime(value: 50, timescale: 10)),
                text: "Cue 1"
            ),
            Cue(
                timeRange: CMTimeRange(start: CMTime(value: 40, timescale: 10), duration: CMTime(value: 30, timescale: 10)), // overlaps at 4.0s
                text: "Cue 2"
            )
        ]

        #expect(throws: SyncInvariantError.self) {
            try engine.validateTimelineContinuity(cues: overlappingCues)
        }
    }

    @Test("Timeline continuity rejects out-of-order cues")
    func test_timeline_continuity_rejects_out_of_order() {
        let outOfOrderCues = [
            Cue(
                timeRange: CMTimeRange(start: CMTime(value: 50, timescale: 10), duration: CMTime(value: 20, timescale: 10)),
                text: "Cue 2 first"
            ),
            Cue(
                timeRange: CMTimeRange(start: CMTime(value: 10, timescale: 10), duration: CMTime(value: 20, timescale: 10)),
                text: "Cue 1 second"
            )
        ]

        #expect(throws: SyncInvariantError.self) {
            try engine.validateTimelineContinuity(cues: outOfOrderCues)
        }
    }

    @Test("Timeline continuity rejects zero or negative duration cue")
    func test_timeline_continuity_rejects_zero_duration() {
        let zeroDurationCues = [
            Cue(
                timeRange: CMTimeRange(start: CMTime(value: 0, timescale: 10), duration: .zero),
                text: "Zero duration"
            )
        ]

        #expect(throws: SyncInvariantError.self) {
            try engine.validateTimelineContinuity(cues: zeroDurationCues)
        }
    }

    @Test("Timeline continuity rejects cues exceeding total project duration")
    func test_timeline_continuity_rejects_exceeding_total_duration() {
        let cues = makeSampleCues() // ends at 10.0s (480000 / 48000)
        let shortProjectDuration = CMTime(value: 8, timescale: 1) // 8.0s

        #expect(throws: SyncInvariantError.self) {
            try engine.validateTimelineContinuity(cues: cues, totalDuration: shortProjectDuration)
        }
    }

    @Test("Cue contains(time:) checks boundary containment accurately")
    func test_cue_contains_time() {
        let cue = Cue(
            timeRange: CMTimeRange(start: CMTime(value: 20, timescale: 10), duration: CMTime(value: 30, timescale: 10)), // 2.0s - 5.0s
            text: "Test"
        )

        #expect(cue.contains(time: CMTime(value: 19, timescale: 10)) == false)
        #expect(cue.contains(time: CMTime(value: 20, timescale: 10)) == true)
        #expect(cue.contains(time: CMTime(value: 35, timescale: 10)) == true)
        #expect(cue.contains(time: CMTime(value: 49, timescale: 10)) == true)
        #expect(cue.contains(time: CMTime(value: 50, timescale: 10)) == false) // open upper bound
        #expect(cue.contains(time: CMTime(value: 60, timescale: 10)) == false)
    }
}
