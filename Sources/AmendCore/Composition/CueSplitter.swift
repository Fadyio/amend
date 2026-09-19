import Foundation
import CoreMedia

/// Errors that may occur during cue splitting.
public enum CueSplitterError: Error, LocalizedError, Equatable, Sendable {
    case targetCueNotFound(UUID)
    case splitTimestampOutOfBounds(splitTime: CMTime, cueRange: CMTimeRange)
    case resultingDurationTooShort(CMTime, minimumRequired: CMTime)

    public var errorDescription: String? {
        switch self {
        case .targetCueNotFound(let id):
            return "Target cue \(id) not found in cues collection."
        case .splitTimestampOutOfBounds(let splitTime, let cueRange):
            return "Split timestamp \(splitTime.seconds)s is outside cue slot range (\(cueRange.start.seconds)s - \(cueRange.end.seconds)s)."
        case .resultingDurationTooShort(let duration, let minReq):
            return "Resulting cue duration (\(duration.seconds)s) is shorter than minimum allowed (\(minReq.seconds)s)."
        }
    }
}

/// Splits cues into continuous, non-overlapping sub-cues with zero temporal gap.
public struct CueSplitter: Sendable {
    public let minimumDuration: CMTime

    /// Initializes a CueSplitter.
    /// - Parameter minimumDuration: Minimum duration required for resulting sub-cues (default: 10ms).
    public init(minimumDuration: CMTime = CMTime(value: 10, timescale: 1000)) {
        self.minimumDuration = minimumDuration
    }

    /// Splits an individual cue at timestamp `splitTime` into `cueA` [start, splitTime] and `cueB` [splitTime, end].
    public func split(
        cue: Cue,
        at splitTime: CMTime,
        textSplitIndex: String.Index? = nil
    ) throws -> (cueA: Cue, cueB: Cue) {
        let start = cue.start
        let end = cue.end

        // Ensure splitTime is strictly inside (start, end)
        if CMTimeCompare(splitTime, start) <= 0 || CMTimeCompare(splitTime, end) >= 0 {
            throw CueSplitterError.splitTimestampOutOfBounds(splitTime: splitTime, cueRange: cue.timeRange)
        }

        // Exact rational subtraction: durationA = splitTime - start; durationB = end - splitTime
        let durationA = CMTimeSubtract(splitTime, start)
        let durationB = CMTimeSubtract(end, splitTime)

        if CMTimeCompare(durationA, minimumDuration) < 0 {
            throw CueSplitterError.resultingDurationTooShort(durationA, minimumRequired: minimumDuration)
        }
        if CMTimeCompare(durationB, minimumDuration) < 0 {
            throw CueSplitterError.resultingDurationTooShort(durationB, minimumRequired: minimumDuration)
        }

        let rangeA = CMTimeRange(start: start, duration: durationA)
        let rangeB = CMTimeRange(start: splitTime, duration: durationB)

        // Text partitioning
        let textA: String
        let textB: String
        if let idx = textSplitIndex, idx >= cue.text.startIndex && idx <= cue.text.endIndex {
            textA = String(cue.text[..<idx]).trimmingCharacters(in: .whitespaces)
            textB = String(cue.text[idx...]).trimmingCharacters(in: .whitespaces)
        } else {
            // Default split: split words proportionally based on time
            let words = cue.text.split(separator: " ")
            if words.count > 1 {
                let ratio = CMTimeGetSeconds(durationA) / CMTimeGetSeconds(cue.duration)
                let splitWordIndex = max(1, min(words.count - 1, Int((Double(words.count) * ratio).rounded())))
                textA = words[..<splitWordIndex].joined(separator: " ")
                textB = words[splitWordIndex...].joined(separator: " ")
            } else {
                textA = cue.text
                textB = cue.text
            }
        }

        let cueA = Cue(
            id: UUID(),
            timeRange: rangeA,
            text: textA,
            originalText: textA,
            audioWAVRelativePath: nil,
            editState: .edited,
            overflowDelta: nil
        )

        let cueB = Cue(
            id: UUID(),
            timeRange: rangeB,
            text: textB,
            originalText: textB,
            audioWAVRelativePath: nil,
            editState: .edited,
            overflowDelta: nil
        )

        return (cueA, cueB)
    }

    /// Splits a cue within a timeline array, ensuring all neighbor cues remain bitwise untouched.
    public func splitCue(
        in cues: [Cue],
        targetCueID: UUID,
        at splitTime: CMTime,
        textSplitIndex: String.Index? = nil
    ) throws -> (updatedCues: [Cue], splitA: Cue, splitB: Cue) {
        guard let index = cues.firstIndex(where: { $0.id == targetCueID }) else {
            throw CueSplitterError.targetCueNotFound(targetCueID)
        }
        let targetCue = cues[index]
        let (cueA, cueB) = try split(cue: targetCue, at: splitTime, textSplitIndex: textSplitIndex)

        var newCues = cues
        newCues.remove(at: index)
        newCues.insert(cueB, at: index)
        newCues.insert(cueA, at: index)

        return (newCues, cueA, cueB)
    }
}
