import Testing
import Foundation
import CoreMedia
@testable import AmendCore

@Suite("Sync Invariant & Cue Splitter Adversarial Stress Suite")
final class SyncInvariantAdversarialTests {
    private let engine = SyncInvariantEngine()
    private let splitter = CueSplitter(minimumDuration: CMTime(value: 10, timescale: 1000)) // 10ms threshold
    private let inspector = AudioTrackInspector()

    // MARK: - 1. Microsecond & Sub-Frame Timestamp Precision Splits

    @Test("Cue split at microsecond precision preserves exact zero gap and duration sum")
    func test_microsecond_precision_split() throws {
        // 0.0s - 2.0s with 1,000,000 timescale (microsecond clock)
        let cue = Cue(
            timeRange: CMTimeRange(
                start: CMTime(value: 0, timescale: 1_000_000),
                duration: CMTime(value: 2_000_000, timescale: 1_000_000)
            ),
            text: "Microsecond precision testing for cue boundaries"
        )
        // Split at 1.234567s
        let splitTime = CMTime(value: 1_234_567, timescale: 1_000_000)

        let (cueA, cueB) = try splitter.split(cue: cue, at: splitTime)

        // Exact rational equality down to 1 microsecond
        #expect(cueA.start.value == 0)
        #expect(cueA.duration.value == 1_234_567)
        #expect(cueA.duration.timescale == 1_000_000)
        #expect(cueB.start.value == 1_234_567)
        #expect(cueB.duration.value == 765_433)
        #expect(cueB.duration.timescale == 1_000_000)

        // Zero gap
        let gap = CMTimeSubtract(cueB.start, cueA.end)
        #expect(CMTimeCompare(gap, .zero) == 0)

        // Zero overlap
        #expect(CMTimeCompare(cueA.end, cueB.start) == 0)

        // Combined duration exactly equals original
        let combinedDuration = CMTimeAdd(cueA.duration, cueB.duration)
        #expect(CMTimeCompare(combinedDuration, cue.duration) == 0)
    }

    @Test("Cue split with mismatched timescales (44.1kHz audio vs 60kHz video ruler)")
    func test_sub_frame_differing_timescales() throws {
        // Audio recorded at 44.1 kHz (timescale 44100)
        let cue = Cue(
            timeRange: CMTimeRange(
                start: CMTime(value: 44100, timescale: 44100), // 1.0s
                duration: CMTime(value: 88200, timescale: 44100) // 2.0s -> end at 3.0s
            ),
            text: "Cross-timescale split verification"
        )
        // Split timestamp on 60,000 timescale (standard video timebase) at 1.75s (105000 / 60000)
        let splitTime = CMTime(value: 105_000, timescale: 60_000)

        let (cueA, cueB) = try splitter.split(cue: cue, at: splitTime)

        #expect(CMTimeCompare(cueA.start, cue.start) == 0)
        #expect(CMTimeCompare(cueA.end, splitTime) == 0)
        #expect(CMTimeCompare(cueB.start, splitTime) == 0)
        #expect(CMTimeCompare(cueB.end, cue.end) == 0)

        // Zero gap & zero overlap
        let gap = CMTimeSubtract(cueB.start, cueA.end)
        #expect(CMTimeCompare(gap, .zero) == 0)
        #expect(CMTimeCompare(cueA.end, cueB.start) == 0)

        let combined = CMTimeAdd(cueA.duration, cueB.duration)
        #expect(CMTimeCompare(combined, cue.duration) == 0)
    }

    @Test("Split boundary microsecond threshold limits")
    func test_split_boundary_microsecond_limits() throws {
        let cue = Cue(
            timeRange: CMTimeRange(
                start: CMTime(value: 0, timescale: 1_000_000),
                duration: CMTime(value: 1_000_000, timescale: 1_000_000) // 1.0s
            ),
            text: "Boundary threshold testing"
        )
        // Minimum duration is 10ms = 10,000 microseconds

        // 1. Split at exactly start + 9,999 microseconds (1 microsecond below minimum) -> must reject
        let tooShortAtHead = CMTime(value: 9_999, timescale: 1_000_000)
        #expect(throws: CueSplitterError.self) {
            try splitter.split(cue: cue, at: tooShortAtHead)
        }

        // 2. Split at start + 10,001 microseconds (1 microsecond above minimum) -> must succeed
        let justOverAtHead = CMTime(value: 10_001, timescale: 1_000_000)
        let (cueA, cueB) = try splitter.split(cue: cue, at: justOverAtHead)
        #expect(CMTimeCompare(cueA.duration, splitter.minimumDuration) > 0)
        #expect(CMTimeCompare(cueB.duration, splitter.minimumDuration) > 0)

        // 3. Split at end - 9,999 microseconds (tail is 9,999 us < 10,000 us) -> must reject
        let tooShortAtTail = CMTime(value: 990_001, timescale: 1_000_000)
        #expect(throws: CueSplitterError.self) {
            try splitter.split(cue: cue, at: tooShortAtTail)
        }

        // 4. Split at end - 10,001 microseconds (tail is 10,001 us > 10,000 us) -> must succeed
        let justOverAtTail = CMTime(value: 989_999, timescale: 1_000_000)
        let (tailA, tailB) = try splitter.split(cue: cue, at: justOverAtTail)
        #expect(CMTimeCompare(tailA.duration, splitter.minimumDuration) > 0)
        #expect(CMTimeCompare(tailB.duration, splitter.minimumDuration) > 0)

        // 5. Split at exact start or end -> must reject as out of bounds
        #expect(throws: CueSplitterError.self) {
            try splitter.split(cue: cue, at: cue.start)
        }
        #expect(throws: CueSplitterError.self) {
            try splitter.split(cue: cue, at: cue.end)
        }
    }

    // MARK: - 2. Repeated Splits (100+ Continuous Splits) & Numerical Drift

    @Test("100 sequential continuous cue splits accumulate zero drift and zero gaps")
    func test_continuous_100_splits_linear_zero_drift() throws {
        // Initial cue: 10.0s with timescale 48000
        let originalCue = Cue(
            timeRange: CMTimeRange(
                start: CMTime(value: 0, timescale: 48000),
                duration: CMTime(value: 480_000, timescale: 48000)
            ),
            text: "Repeated splitting stress test across one hundred segments"
        )

        var timeline = [originalCue]
        let splitCount = 99 // 99 splits produces 100 cues

        for i in 1...splitCount {
            // Split the last cue at i * 0.1s = i * 4800 ticks
            guard let lastCue = timeline.last else { break }
            let splitTime = CMTime(value: Int64(i) * 4800, timescale: 48000)

            let (updatedTimeline, _, _) = try splitter.splitCue(
                in: timeline,
                targetCueID: lastCue.id,
                at: splitTime
            )
            timeline = updatedTimeline
        }

        #expect(timeline.count == 100)

        // Invariance 1: Every adjacent pair must have exactly ZERO gap and ZERO overlap
        for i in 0..<(timeline.count - 1) {
            let left = timeline[i]
            let right = timeline[i + 1]

            // CMTime equality
            #expect(CMTimeCompare(left.end, right.start) == 0)

            // Gap subtraction is exact zero
            let gap = CMTimeSubtract(right.start, left.end)
            #expect(CMTimeCompare(gap, .zero) == 0)
            #expect(gap.value == 0)
        }

        // Invariance 2: Sum of all 100 durations must equal the original cue duration with ZERO drift
        var totalSum = CMTime.zero
        for c in timeline {
            totalSum = CMTimeAdd(totalSum, c.duration)
        }
        #expect(CMTimeCompare(totalSum, originalCue.duration) == 0)
        #expect(totalSum.value == originalCue.duration.value)
        #expect(totalSum.timescale == originalCue.duration.timescale)

        // Invariance 3: Entire 100-cue timeline satisfies timeline continuity
        try engine.validateTimelineContinuity(cues: timeline, totalDuration: originalCue.duration)
    }

    @Test("50 binary splits in tree pattern preserve rational timeline exactness")
    func test_continuous_binary_splitting_zero_drift() throws {
        // Cue: 102.4s = 102,400 ms (allows repeated halvings down to > 10ms)
        let originalCue = Cue(
            timeRange: CMTimeRange(
                start: CMTime(value: 0, timescale: 1000),
                duration: CMTime(value: 102_400, timescale: 1000)
            ),
            text: "Binary tree split test"
        )

        var cues = [originalCue]

        // Halve cues 6 times: 1 -> 2 -> 4 -> 8 -> 16 -> 32 -> 64 cues
        for _ in 0..<6 {
            var nextCues: [Cue] = []
            for c in cues {
                let halfDuration = CMTimeMultiplyByFloat64(c.duration, multiplier: 0.5)
                let splitTime = CMTimeAdd(c.start, halfDuration)
                let (cueA, cueB) = try splitter.split(cue: c, at: splitTime)
                nextCues.append(cueA)
                nextCues.append(cueB)
            }
            cues = nextCues
        }

        #expect(cues.count == 64)

        // Verify zero gap and zero overlap across all 64 cues
        for i in 0..<(cues.count - 1) {
            #expect(CMTimeCompare(cues[i].end, cues[i + 1].start) == 0)
        }

        let total = cues.reduce(CMTime.zero) { CMTimeAdd($0, $1.duration) }
        #expect(CMTimeCompare(total, originalCue.duration) == 0)
        try engine.validateTimelineContinuity(cues: cues, totalDuration: originalCue.duration)
    }

    // MARK: - 3. Non-Target Cue Mutation Resistance & Edge Invariants

    @Test("assertSyncInvariant catches non-target text mutation")
    func test_assert_sync_invariant_catches_text_mutation() {
        let cues = [
            Cue(timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)), text: "A"),
            Cue(timeRange: CMTimeRange(start: CMTime(value: 1, timescale: 1), duration: CMTime(value: 1, timescale: 1)), text: "B")
        ]
        var mutated = cues
        mutated[1] = Cue(
            id: cues[1].id,
            timeRange: cues[1].timeRange,
            text: "B Mutated",
            originalText: cues[1].originalText
        )

        #expect(throws: SyncInvariantError.self) {
            try engine.assertSyncInvariant(before: cues, after: mutated, modifiedCueID: cues[0].id)
        }
    }

    @Test("assertSyncInvariant catches non-target audio path mutation")
    func test_assert_sync_invariant_catches_audio_path_mutation() {
        let cues = [
            Cue(timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)), text: "A"),
            Cue(timeRange: CMTimeRange(start: CMTime(value: 1, timescale: 1), duration: CMTime(value: 1, timescale: 1)), text: "B")
        ]
        var mutated = cues
        mutated[1] = Cue(
            id: cues[1].id,
            timeRange: cues[1].timeRange,
            text: cues[1].text,
            originalText: cues[1].originalText,
            audioWAVRelativePath: "injected.wav"
        )

        #expect(throws: SyncInvariantError.self) {
            try engine.assertSyncInvariant(before: cues, after: mutated, modifiedCueID: cues[0].id)
        }
    }

    @Test("assertSyncInvariant catches non-target edit state mutation")
    func test_assert_sync_invariant_catches_edit_state_mutation() {
        let cues = [
            Cue(timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)), text: "A"),
            Cue(timeRange: CMTimeRange(start: CMTime(value: 1, timescale: 1), duration: CMTime(value: 1, timescale: 1)), text: "B")
        ]
        var mutated = cues
        mutated[1] = Cue(
            id: cues[1].id,
            timeRange: cues[1].timeRange,
            text: cues[1].text,
            originalText: cues[1].originalText,
            editState: .forceFitted
        )

        #expect(throws: SyncInvariantError.self) {
            try engine.assertSyncInvariant(before: cues, after: mutated, modifiedCueID: cues[0].id)
        }
    }

    @Test("assertSyncInvariant catches cue reordering or insertion/deletion")
    func test_assert_sync_invariant_catches_structural_changes() {
        let cues = [
            Cue(timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)), text: "A"),
            Cue(timeRange: CMTimeRange(start: CMTime(value: 1, timescale: 1), duration: CMTime(value: 1, timescale: 1)), text: "B")
        ]

        // 1. Swapped order
        let swapped = [cues[1], cues[0]]
        #expect(throws: SyncInvariantError.self) {
            try engine.assertSyncInvariant(before: cues, after: swapped, modifiedCueID: cues[0].id)
        }

        // 2. Count mismatch (deleted cue)
        let deleted = [cues[0]]
        #expect(throws: SyncInvariantError.self) {
            try engine.assertSyncInvariant(before: cues, after: deleted, modifiedCueID: cues[0].id)
        }

        // 3. Count mismatch (added cue)
        let added = cues + [Cue(timeRange: CMTimeRange(start: CMTime(value: 2, timescale: 1), duration: CMTime(value: 1, timescale: 1)), text: "C")]
        #expect(throws: SyncInvariantError.self) {
            try engine.assertSyncInvariant(before: cues, after: added, modifiedCueID: cues[0].id)
        }
    }

    @Test("assertSyncInvariant catches sub-tick boundary shift of 1 microsecond")
    func test_assert_sync_invariant_catches_microsecond_shift() {
        let cues = [
            Cue(
                timeRange: CMTimeRange(
                    start: CMTime(value: 1_000_000, timescale: 1_000_000),
                    duration: CMTime(value: 1_000_000, timescale: 1_000_000)
                ),
                text: "Target"
            )
        ]
        var shifted = cues
        shifted[0] = Cue(
            id: cues[0].id,
            timeRange: CMTimeRange(
                start: CMTime(value: 1_000_001, timescale: 1_000_000), // 1 microsecond shift!
                duration: cues[0].duration
            ),
            text: "Target"
        )

        #expect(throws: SyncInvariantError.self) {
            try engine.assertSyncInvariant(before: cues, after: shifted, modifiedCueID: cues[0].id)
        }
    }

    // MARK: - 4. Timeline Continuity Invariant Stress Testing

    @Test("validateTimelineContinuity detects microsecond overlap between cues")
    func test_timeline_continuity_microsecond_overlap() {
        let cues = [
            Cue(
                timeRange: CMTimeRange(
                    start: CMTime(value: 0, timescale: 1_000_000),
                    duration: CMTime(value: 1_000_000, timescale: 1_000_000) // [0, 1.0s]
                ),
                text: "First"
            ),
            Cue(
                timeRange: CMTimeRange(
                    start: CMTime(value: 999_999, timescale: 1_000_000), // Overlaps by 1 microsecond!
                    duration: CMTime(value: 1_000_000, timescale: 1_000_000)
                ),
                text: "Second"
            )
        ]

        #expect {
            try engine.validateTimelineContinuity(cues: cues)
        } throws: { error in
            guard case SyncInvariantError.overlappingCues = error else { return false }
            return true
        }
    }

    @Test("validateTimelineContinuity detects microsecond out-of-order cues")
    func test_timeline_continuity_microsecond_out_of_order() {
        let cues = [
            Cue(
                timeRange: CMTimeRange(
                    start: CMTime(value: 1_000_000, timescale: 1_000_000),
                    duration: CMTime(value: 500_000, timescale: 1_000_000)
                ),
                text: "First"
            ),
            Cue(
                timeRange: CMTimeRange(
                    start: CMTime(value: 999_999, timescale: 1_000_000), // Starts 1 microsecond before previous!
                    duration: CMTime(value: 500_000, timescale: 1_000_000)
                ),
                text: "Second"
            )
        ]

        #expect {
            try engine.validateTimelineContinuity(cues: cues)
        } throws: { error in
            guard case SyncInvariantError.cuesOutOfChronologicalOrder = error else { return false }
            return true
        }
    }

    @Test("validateTimelineContinuity validates contiguous and non-contiguous valid timelines")
    func test_timeline_continuity_contiguous_and_gaps() throws {
        // 1. Contiguous (touching boundaries)
        let contiguousCues = [
            Cue(timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 10, timescale: 1)), text: "1"),
            Cue(timeRange: CMTimeRange(start: CMTime(value: 10, timescale: 1), duration: CMTime(value: 10, timescale: 1)), text: "2"),
            Cue(timeRange: CMTimeRange(start: CMTime(value: 20, timescale: 1), duration: CMTime(value: 10, timescale: 1)), text: "3")
        ]
        try engine.validateTimelineContinuity(cues: contiguousCues, totalDuration: CMTime(value: 30, timescale: 1))

        // 2. Timeline with silence gaps between cues
        let gappedCues = [
            Cue(timeRange: CMTimeRange(start: CMTime(value: 2, timescale: 1), duration: CMTime(value: 3, timescale: 1)), text: "1"), // 2-5s
            Cue(timeRange: CMTimeRange(start: CMTime(value: 7, timescale: 1), duration: CMTime(value: 2, timescale: 1)), text: "2"), // 7-9s (2s gap)
            Cue(timeRange: CMTimeRange(start: CMTime(value: 12, timescale: 1), duration: CMTime(value: 1, timescale: 1)), text: "3") // 12-13s (3s gap)
        ]
        try engine.validateTimelineContinuity(cues: gappedCues, totalDuration: CMTime(value: 20, timescale: 1))
    }

    @Test("validateTimelineContinuity rejects total duration exceeded by exactly 1 tick")
    func test_timeline_continuity_exceeded_by_one_tick() {
        let maxDuration = CMTime(value: 10_000, timescale: 1000) // 10.0s
        let cues = [
            Cue(
                timeRange: CMTimeRange(
                    start: CMTime(value: 0, timescale: 1000),
                    duration: CMTime(value: 10_001, timescale: 1000) // 10.001s
                ),
                text: "Over total duration"
            )
        ]

        #expect {
            try engine.validateTimelineContinuity(cues: cues, totalDuration: maxDuration)
        } throws: { error in
            guard case SyncInvariantError.timeExceedsProjectDuration = error else { return false }
            return true
        }
    }

    // MARK: - 5. AudioTrackInspector & AudioTrackMapping Adversarial Challenges

    @Test("Inspector handles extreme sample rates and channel configurations")
    func test_inspector_extreme_audio_characteristics() throws {
        let exoticTracks = [
            AudioTrackInfo(
                id: 1,
                format: "lpcm",
                channelCount: 8, // 7.1 surround sound
                sampleRate: 192_000.0, // High-res studio audio
                bitDepth: 24,
                duration: CMTime(value: 60, timescale: 1),
                timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 60, timescale: 1)),
                languageCode: "en-US",
                title: "Studio Surround Master",
                estimatedDataRate: 36_864_000.0
            ),
            AudioTrackInfo(
                id: 2,
                format: "flac",
                channelCount: 1, // Mono
                sampleRate: 44_100.0,
                bitDepth: 16,
                duration: CMTime(value: 60, timescale: 1),
                timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 60, timescale: 1))
            )
        ]

        let mapping = AudioTrackMapping.multiTrack(narrationTrackID: 1, passthroughTrackIDs: [2])
        #expect(mapping.isValid)
        try inspector.validate(mapping: mapping, against: exoticTracks)

        // Codable round-trip for AudioTrackInfo
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(exoticTracks[0])
        let decoded = try decoder.decode(AudioTrackInfo.self, from: data)
        #expect(decoded == exoticTracks[0])
    }

    @Test("Inspector handles negative and zero track IDs without crashing")
    func test_inspector_negative_track_ids() throws {
        // In AVFoundation, trackID is CMPersistentTrackID (int32_t).
        // Test handling of edge-case track IDs.
        let tracksWithEdgeIDs = [
            AudioTrackInfo(
                id: -1,
                format: "aac",
                channelCount: 2,
                sampleRate: 48000.0,
                duration: CMTime(value: 10, timescale: 1),
                timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 10, timescale: 1))
            ),
            AudioTrackInfo(
                id: 0,
                format: "lpcm",
                channelCount: 2,
                sampleRate: 48000.0,
                duration: CMTime(value: 10, timescale: 1),
                timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 10, timescale: 1))
            )
        ]

        let mapping = AudioTrackMapping(
            designatedNarrationTrackID: -1,
            passthroughTrackIDs: [0],
            isSingleTrackAdvisory: false
        )
        #expect(mapping.isValid)
        try inspector.validate(mapping: mapping, against: tracksWithEdgeIDs)
    }

    @Test("Inspector rejects passthrough track ID not found in asset")
    func test_inspector_rejects_missing_passthrough() {
        let tracks = [
            AudioTrackInfo(
                id: 1,
                format: "lpcm",
                channelCount: 2,
                sampleRate: 48000.0,
                duration: CMTime(value: 10, timescale: 1),
                timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 10, timescale: 1))
            )
        ]

        let invalidMapping = AudioTrackMapping(
            designatedNarrationTrackID: 1,
            passthroughTrackIDs: [99],
            isSingleTrackAdvisory: false
        )

        #expect {
            try inspector.validate(mapping: invalidMapping, against: tracks)
        } throws: { error in
            guard case AudioTrackInspectorError.passthroughTrackNotInAsset(99) = error else { return false }
            return true
        }
    }

    // MARK: - 6. Text Splitting Stress Testing (Unicode, Emojis, Empty)

    @Test("Cue text splitting with multi-byte unicode and complex emojis")
    func test_cue_text_splitting_unicode() throws {
        let complexText = "👨‍👩‍👧‍👦 Swift 🚀 Concurrency ⚡️ Timeline 🎯"
        let cue = Cue(
            timeRange: CMTimeRange(
                start: .zero,
                duration: CMTime(value: 4000, timescale: 1000)
            ),
            text: complexText
        )

        // Split in middle
        let splitTime = CMTime(value: 2000, timescale: 1000)
        let (cueA, cueB) = try splitter.split(cue: cue, at: splitTime)

        #expect(!cueA.text.isEmpty)
        #expect(!cueB.text.isEmpty)
        // Combined text should contain words
        #expect(cueA.text.contains("Swift") || cueB.text.contains("Swift"))
    }

    @Test("Cue text splitting with single word preserves word in both cues")
    func test_cue_text_splitting_single_word() throws {
        let cue = Cue(
            timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 2000, timescale: 1000)),
            text: "Supercalifragilisticexpialidocious"
        )
        let splitTime = CMTime(value: 1000, timescale: 1000)
        let (cueA, cueB) = try splitter.split(cue: cue, at: splitTime)

        #expect(cueA.text == "Supercalifragilisticexpialidocious")
        #expect(cueB.text == "Supercalifragilisticexpialidocious")
    }

    @Test("Cue text splitting with explicit index boundary at string start and end")
    func test_cue_text_splitting_explicit_index_boundaries() throws {
        let text = "Hello World"
        let cue = Cue(
            timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 2000, timescale: 1000)),
            text: text
        )
        let splitTime = CMTime(value: 1000, timescale: 1000)

        // Split at start of text
        let (cueA1, cueB1) = try splitter.split(cue: cue, at: splitTime, textSplitIndex: text.startIndex)
        #expect(cueA1.text == "")
        #expect(cueB1.text == "Hello World")

        // Split at end of text
        let (cueA2, cueB2) = try splitter.split(cue: cue, at: splitTime, textSplitIndex: text.endIndex)
        #expect(cueA2.text == "Hello World")
        #expect(cueB2.text == "")
    }

    // MARK: - 7. Concurrency & Isolation Stress

    @Test("Concurrent timeline mutations across independent tasks maintain complete isolation")
    func test_concurrent_timeline_updates_isolation() async throws {
        let initialCues = (0..<20).map { i -> Cue in
            Cue(
                timeRange: CMTimeRange(
                    start: CMTime(value: Int64(i * 1000), timescale: 1000),
                    duration: CMTime(value: 1000, timescale: 1000)
                ),
                text: "Original cue #\(i)",
                originalText: "Original cue #\(i)"
            )
        }

        let engineRef = engine

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let targetID = initialCues[i].id
                    do {
                        let updated = try engineRef.updateCueText(
                            in: initialCues,
                            cueID: targetID,
                            newText: "Updated narration for cue #\(i)"
                        )
                        #expect(updated[i].text == "Updated narration for cue #\(i)")
                        // Check neighbor immutability
                        if i > 0 {
                            #expect(updated[i - 1].text == initialCues[i - 1].text)
                            #expect(CMTimeCompare(updated[i - 1].start, initialCues[i - 1].start) == 0)
                        }
                    } catch {
                        #expect(Bool(false), "Concurrent update failed: \(error)")
                    }
                }
            }
        }
    }

    // MARK: - 8. Invariant Blind Spots & Edge Probes

    @Test("assertSyncInvariant non-target originalText mutation detection")
    func test_assert_sync_invariant_non_target_original_text() {
        let cues = [
            Cue(timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)), text: "A", originalText: "Original A"),
            Cue(timeRange: CMTimeRange(start: CMTime(value: 1, timescale: 1), duration: CMTime(value: 1, timescale: 1)), text: "B", originalText: "Original B")
        ]
        var mutated = cues
        // Mutate originalText of non-target cue 1
        mutated[1] = Cue(
            id: cues[1].id,
            timeRange: cues[1].timeRange,
            text: cues[1].text,
            originalText: "Tampered Original B",
            audioWAVRelativePath: cues[1].audioWAVRelativePath,
            editState: cues[1].editState,
            overflowDelta: cues[1].overflowDelta
        )

        // SyncInvariantEngine.assertSyncInvariant checks non-target cues:
        // Line 106: if b.text != a.text || b.audioWAVRelativePath != a.audioWAVRelativePath || b.editState != a.editState
        // Let's verify whether it catches or misses originalText mutation:
        let caught: Bool
        do {
            try engine.assertSyncInvariant(before: cues, after: mutated, modifiedCueID: cues[0].id)
            caught = false
        } catch {
            caught = true
        }

        // We record the empirical behavior of whether assertSyncInvariant checks originalText:
        // In the current implementation, line 106 only checks text, audioWAVRelativePath, and editState.
        // It does NOT check originalText!
        #expect(caught == false, "Documented finding: assertSyncInvariant currently misses non-target originalText mutations")
    }

    @Test("assertSyncInvariant non-target overflowDelta mutation detection")
    func test_assert_sync_invariant_non_target_overflow_delta() {
        let cues = [
            Cue(timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)), text: "A"),
            Cue(timeRange: CMTimeRange(start: CMTime(value: 1, timescale: 1), duration: CMTime(value: 1, timescale: 1)), text: "B")
        ]
        var mutated = cues
        // Mutate overflowDelta of non-target cue 1
        mutated[1] = Cue(
            id: cues[1].id,
            timeRange: cues[1].timeRange,
            text: cues[1].text,
            originalText: cues[1].originalText,
            audioWAVRelativePath: cues[1].audioWAVRelativePath,
            editState: cues[1].editState,
            overflowDelta: CMTime(value: 500, timescale: 1000)
        )

        let caught: Bool
        do {
            try engine.assertSyncInvariant(before: cues, after: mutated, modifiedCueID: cues[0].id)
            caught = false
        } catch {
            caught = true
        }

        // In the current implementation, line 106 only checks text, audioWAVRelativePath, and editState.
        // It does NOT check overflowDelta!
        #expect(caught == false, "Documented finding: assertSyncInvariant currently misses non-target overflowDelta mutations")
    }

    @Test("validateTimelineContinuity behavior on negative cue start time")
    func test_timeline_continuity_negative_start_time() {
        let cues = [
            Cue(
                timeRange: CMTimeRange(
                    start: CMTime(value: -5, timescale: 1), // Starts at -5.0s!
                    duration: CMTime(value: 2, timescale: 1) // Ends at -3.0s!
                ),
                text: "Negative start cue"
            )
        ]

        let throwsError: Bool
        do {
            try engine.validateTimelineContinuity(cues: cues)
            throwsError = false
        } catch {
            throwsError = true
        }

        // Empirical check: validateTimelineContinuity checks duration > 0 and chronological order,
        // but does not explicitly guard against start < 0.
        #expect(throwsError == false, "Documented finding: validateTimelineContinuity does not reject negative start times when duration is positive")
    }

    @Test("AudioTrackMapping.isValid with duplicate passthrough IDs")
    func test_audio_track_mapping_is_valid_with_duplicates() {
        let mapping = AudioTrackMapping(
            designatedNarrationTrackID: 1,
            passthroughTrackIDs: [2, 2],
            isSingleTrackAdvisory: false
        )

        // AudioTrackMapping.isValid currently checks:
        // !passthroughTrackIDs.contains(designatedNarrationTrackID) && (!isSingleTrackAdvisory || passthroughTrackIDs.isEmpty)
        // Notice it does NOT check Set(passthroughTrackIDs).count == passthroughTrackIDs.count.
        // Meanwhile AudioTrackInspector.validate DOES throw duplicatePassthroughTrackIDs.
        #expect(mapping.isValid == true, "Documented finding: mapping.isValid is true even with duplicates, while inspector.validate catches it")
    }

    @Test("AudioTrackInspector inspection of 0-byte media file throws unreadableAsset")
    func test_audio_track_inspector_zero_byte_file() async throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("zero_byte_\(UUID().uuidString).mp4")
        try Data().write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        await #expect(throws: AudioTrackInspectorError.self) {
            try await inspector.inspect(assetURL: tempFile)
        }
    }
}

