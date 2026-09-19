import Foundation
import CoreMedia

/// Errors related to fixed-slot synchronization and timeline continuity invariant checks.
public enum SyncInvariantError: Error, LocalizedError, Equatable, Sendable {
    case cueNotFound(UUID)
    case overlappingCues(cueA: UUID, cueB: UUID, rangeA: CMTimeRange, rangeB: CMTimeRange)
    case cuesOutOfChronologicalOrder(cueA: UUID, cueB: UUID)
    case zeroOrNegativeDuration(UUID, CMTime)
    case timeExceedsProjectDuration(UUID, CMTime, CMTime)
    case invariantViolationBoundaryShifted(cueID: UUID, expected: CMTimeRange, actual: CMTimeRange)
    case nonTargetCueMutated(cueID: UUID)

    public var errorDescription: String? {
        switch self {
        case .cueNotFound(let id):
            return "Cue with ID \(id) not found in timeline."
        case .overlappingCues(let a, let b, let rA, let rB):
            return "Cues overlap in timeline: \(a) (\(rA.start.seconds)-\(rA.end.seconds)s) and \(b) (\(rB.start.seconds)-\(rB.end.seconds)s)."
        case .cuesOutOfChronologicalOrder(let a, let b):
            return "Cues are out of chronological order: \(a) appears before \(b) but has later start time."
        case .zeroOrNegativeDuration(let id, let duration):
            return "Cue \(id) has non-positive duration: \(duration.seconds)s."
        case .timeExceedsProjectDuration(let id, let time, let max):
            return "Cue \(id) boundary (\(time.seconds)s) exceeds project duration (\(max.seconds)s)."
        case .invariantViolationBoundaryShifted(let id, let expected, let actual):
            return "Sync invariant violation: Cue \(id) boundary shifted from \(expected) to \(actual)."
        case .nonTargetCueMutated(let id):
            return "Sync invariant violation: Non-target cue \(id) was mutated during slot update."
        }
    }
}

/// Enforces fixed-slot timeline synchronization guarantees using exact rational CMTime arithmetic.
public struct SyncInvariantEngine: Sendable {
    public init() {}

    /// Updates narration text for a target cue, strictly guaranteeing that all cue boundaries remain immutable.
    public func updateCueText(
        in cues: [Cue],
        cueID: UUID,
        newText: String
    ) throws -> [Cue] {
        guard let index = cues.firstIndex(where: { $0.id == cueID }) else {
            throw SyncInvariantError.cueNotFound(cueID)
        }
        let originalCue = cues[index]
        let updatedCue = originalCue.withUpdatedText(newText)

        var newCues = cues
        newCues[index] = updatedCue

        try assertSyncInvariant(before: cues, after: newCues, modifiedCueID: cueID)
        return newCues
    }

    /// Updates audio replacement for a target cue, strictly guaranteeing immutable slot boundaries.
    public func updateCueAudio(
        in cues: [Cue],
        cueID: UUID,
        audioRelativePath: String?,
        editState: CueEditState,
        overflowDelta: CMTime? = nil
    ) throws -> [Cue] {
        guard let index = cues.firstIndex(where: { $0.id == cueID }) else {
            throw SyncInvariantError.cueNotFound(cueID)
        }
        let originalCue = cues[index]
        let updatedCue = originalCue.withUpdatedAudio(
            audioWAVRelativePath: audioRelativePath,
            editState: editState,
            overflowDelta: overflowDelta
        )

        var newCues = cues
        newCues[index] = updatedCue

        try assertSyncInvariant(before: cues, after: newCues, modifiedCueID: cueID)
        return newCues
    }

    /// Verifies the fixed-slot invariant: non-target cues must be identical; target cue timeRange must be identical.
    public func assertSyncInvariant(
        before: [Cue],
        after: [Cue],
        modifiedCueID: UUID
    ) throws {
        guard before.count == after.count else {
            throw SyncInvariantError.nonTargetCueMutated(cueID: modifiedCueID)
        }
        for (b, a) in zip(before, after) {
            guard b.id == a.id else {
                throw SyncInvariantError.nonTargetCueMutated(cueID: a.id)
            }
            // Strict rational CMTime comparison
            if CMTimeCompare(b.timeRange.start, a.timeRange.start) != 0 ||
               CMTimeCompare(b.timeRange.duration, a.timeRange.duration) != 0 {
                throw SyncInvariantError.invariantViolationBoundaryShifted(
                    cueID: a.id,
                    expected: b.timeRange,
                    actual: a.timeRange
                )
            }
            if b.id != modifiedCueID {
                // Non-target cues must have untouched text and audio
                if b.text != a.text || b.audioWAVRelativePath != a.audioWAVRelativePath || b.editState != a.editState {
                    throw SyncInvariantError.nonTargetCueMutated(cueID: a.id)
                }
            }
        }
    }

    /// Validates chronological ordering, non-overlap, and positive duration for a list of cues.
    public func validateTimelineContinuity(
        cues: [Cue],
        totalDuration: CMTime? = nil
    ) throws {
        for i in 0..<cues.count {
            let current = cues[i]
            if CMTimeCompare(current.duration, .zero) <= 0 {
                throw SyncInvariantError.zeroOrNegativeDuration(current.id, current.duration)
            }
            if i > 0 {
                let prev = cues[i - 1]
                if CMTimeCompare(current.start, prev.start) < 0 {
                    throw SyncInvariantError.cuesOutOfChronologicalOrder(cueA: prev.id, cueB: current.id)
                }
                if CMTimeCompare(current.start, prev.end) < 0 {
                    throw SyncInvariantError.overlappingCues(
                        cueA: prev.id,
                        cueB: current.id,
                        rangeA: prev.timeRange,
                        rangeB: current.timeRange
                    )
                }
            }
            if let maxDuration = totalDuration {
                if CMTimeCompare(current.end, maxDuration) > 0 {
                    throw SyncInvariantError.timeExceedsProjectDuration(current.id, current.end, maxDuration)
                }
            }
        }
    }
}
