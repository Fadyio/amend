import Foundation
import CoreMedia
import Combine
import AVFoundation
import MacDubCore
import SwiftTimecodeCore

/// Dedicated isolated leaf clock providing high-frequency 60Hz/120Hz playhead coordinate updates
/// without invalidating parent timeline track body views.
@MainActor
public final class PlayheadClock: ObservableObject {
    @Published public private(set) var playheadX: Double = 0.0
    @Published public private(set) var currentTime: CMTime = .zero

    public init() {}

    public func update(time: CMTime, pps: Double) {
        guard time.isValid && !time.isIndefinite else { return }
        self.currentTime = time
        let seconds = CMTimeGetSeconds(time)
        self.playheadX = max(0.0, seconds * pps)
    }
}

/// Throttled, single-in-flight video seeking controller preventing AVPlayer queue chokes during dragging.
@MainActor
public final class TimelineScrubberController {
    private weak var player: AVPlayer?
    private var isSeeking = false
    private var pendingSeekTime: CMTime?
    public private(set) var isScrubbing = false

    public init(player: AVPlayer?) {
        self.player = player
    }

    public func updatePlayer(_ newPlayer: AVPlayer?) {
        self.player = newPlayer
    }

    public func beginScrubbing() {
        isScrubbing = true
        player?.pause()
    }

    public func scrub(to targetTime: CMTime, exact: Bool = false) {
        guard let player = player else { return }

        if isSeeking {
            pendingSeekTime = targetTime
            return
        }

        isSeeking = true
        let tolerance: CMTime = exact ? .zero : CMTime(value: 1, timescale: 30)

        player.seek(to: targetTime, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.isSeeking = false
                if let next = self.pendingSeekTime {
                    self.pendingSeekTime = nil
                    self.scrub(to: next, exact: exact)
                }
            }
        }
    }

    public func endScrubbing(finalTime: CMTime, resumePlayback: Bool) {
        isScrubbing = false
        pendingSeekTime = nil
        scrub(to: finalTime, exact: true)
        if resumePlayback {
            player?.play()
        }
    }
}

/// Central ViewModel coordinating timeline zoom, scroll offsets, playhead position, cue selection,
/// and video seek dispatching.
@MainActor
public final class TimelineViewModel: ObservableObject {
    // Zoom & Coordinates
    @Published public var pixelsPerSecond: Double = 100.0
    @Published public var scrollOffsetX: Double = 0.0
    @Published public var viewportWidth: Double = 1200.0

    // Selection & Highlighting
    @Published public var selectedCueID: UUID?
    @Published public private(set) var activeCueID: UUID?
    @Published public var hoveredCueID: UUID?

    // Interaction Modes
    @Published public var isSnappingEnabled: Bool = true
    @Published public private(set) var isScrubbing: Bool = false

    // Dependencies
    public let clock: TimelineClock
    public let playheadClock: PlayheadClock
    public let snapper: PlayheadSnapper
    public var rulerFormatter: SMPTERulerFormatter
    public let filmstripGenerator: FilmstripGenerating
    private let scrubber: TimelineScrubberController
    public private(set) var cues: [Cue] = []
    public private(set) var totalDuration: CMTime = .zero

    // Thumbnails
    @Published public var thumbnails: [FilmstripThumbnail] = []
    private var thumbnailLoadTask: Task<Void, Never>?

    private var cancellables = Set<AnyCancellable>()
    private var lastActiveIndex: Int?

    public init(
        clock: TimelineClock,
        player: AVPlayer? = nil,
        frameRate: TimecodeFrameRate = .fps30,
        filmstripGenerator: FilmstripGenerating = FilmstripGenerator()
    ) {
        self.clock = clock
        self.playheadClock = PlayheadClock()
        self.snapper = PlayheadSnapper()
        self.rulerFormatter = SMPTERulerFormatter(frameRate: frameRate)
        self.scrubber = TimelineScrubberController(player: player)
        self.filmstripGenerator = filmstripGenerator

        setupSubscriptions()
    }

    public var converter: TimelineCoordinateConverter {
        TimelineCoordinateConverter(pixelsPerSecond: pixelsPerSecond)
    }

    public func setCues(_ newCues: [Cue], totalDuration: CMTime) {
        self.cues = newCues.sorted(by: { CMTimeCompare($0.start, $1.start) < 0 })
        self.totalDuration = totalDuration
        self.clock.setDuration(totalDuration)
    }

    public func updatePlayer(_ player: AVPlayer) {
        clock.attach(player: player)
        scrubber.updatePlayer(player)
    }

    private func setupSubscriptions() {
        clock.timePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] time in
                guard let self = self else { return }
                self.playheadClock.update(time: time, pps: self.pixelsPerSecond)
                self.updateActiveCue(at: time)
            }
            .store(in: &cancellables)
    }

    private func updateActiveCue(at time: CMTime) {
        if let idx = lastActiveIndex, idx < cues.count {
            let current = cues[idx]
            if current.contains(time: time) {
                return
            }
            let nextIdx = idx + 1
            if nextIdx < cues.count && cues[nextIdx].contains(time: time) {
                lastActiveIndex = nextIdx
                activeCueID = cues[nextIdx].id
                return
            }
        }

        if let foundIdx = cues.indexOfCue(at: time) {
            lastActiveIndex = foundIdx
            if activeCueID != cues[foundIdx].id {
                activeCueID = cues[foundIdx].id
            }
        } else {
            lastActiveIndex = nil
            if activeCueID != nil {
                activeCueID = nil
            }
        }
    }

    public func selectCue(_ cue: Cue) {
        selectedCueID = cue.id
        seek(to: cue.start)
    }

    public func seek(to time: CMTime) {
        clock.seek(to: time)
    }

    public func handlePinchZoom(magnification: Double, anchorViewportX: Double) {
        let newPPS = max(10.0, min(1000.0, pixelsPerSecond * magnification))
        applyZoom(newPPS: newPPS, anchorViewportX: anchorViewportX)
    }

    public func applyZoom(newPPS: Double, anchorViewportX: Double) {
        let clamped = max(10.0, min(1000.0, newPPS))
        guard clamped != pixelsPerSecond else { return }

        let newOffset = TimelineCoordinateConverter.preservedScrollOffset(
            currentOffset: scrollOffsetX,
            oldPPS: pixelsPerSecond,
            newPPS: clamped,
            anchorViewportX: anchorViewportX,
            totalDuration: totalDuration,
            viewportWidth: viewportWidth
        )

        self.pixelsPerSecond = clamped
        self.scrollOffsetX = newOffset
        self.playheadClock.update(time: clock.currentTime, pps: clamped)
    }

    public func beginScrubbing() {
        isScrubbing = true
        clock.beginScrubbing()
        scrubber.beginScrubbing()
    }

    public func updateScrub(to rawX: Double, bypassSnapping: Bool = false) {
        let rawTime = converter.xToTime(rawX)
        let snapResult = snapper.snap(
            rawTime: rawTime,
            cues: cues,
            totalDuration: totalDuration,
            pixelsPerSecond: pixelsPerSecond,
            bypassSnapping: !isSnappingEnabled || bypassSnapping
        )
        let effectiveTime = snapResult.snappedTime
        clock.updateScrub(to: effectiveTime)
        scrubber.scrub(to: effectiveTime, exact: false)
        playheadClock.update(time: effectiveTime, pps: pixelsPerSecond)
    }

    public func endScrubbing(resumePlayback: Bool? = nil) {
        isScrubbing = false
        snapper.reset()
        clock.endScrubbing(resumePlayback: resumePlayback)
        scrubber.endScrubbing(finalTime: clock.currentTime, resumePlayback: resumePlayback ?? clock.isPlaying)
    }

    public func splitCueAtPlayhead() throws {
        let playhead = clock.currentTime
        guard let cueToSplit = cues.first(where: { $0.contains(time: playhead) }) else { return }
        let splitter = CueSplitter()
        let (cueA, cueB) = try splitter.split(cue: cueToSplit, at: playhead)
        var updated = cues
        if let idx = updated.firstIndex(where: { $0.id == cueToSplit.id }) {
            updated.remove(at: idx)
            updated.insert(cueB, at: idx)
            updated.insert(cueA, at: idx)
            setCues(updated, totalDuration: totalDuration)
            selectedCueID = cueA.id
        }
    }

    public func reloadThumbnails(for sourceURL: URL?) {
        guard let url = sourceURL, totalDuration > .zero else { return }
        thumbnailLoadTask?.cancel()

        let visibleRect = CGRect(
            x: scrollOffsetX,
            y: 0,
            width: max(100.0, viewportWidth),
            height: 50
        )
        let request = FilmstripRequest(
            assetURL: url,
            totalDuration: totalDuration,
            pixelsPerSecond: pixelsPerSecond,
            thumbnailWidth: 80.0,
            thumbnailHeight: 50.0,
            visibleRect: visibleRect,
            displayScale: 2.0
        )

        thumbnailLoadTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let stream = self.filmstripGenerator.thumbnailStream(for: request, cacheDirectory: nil)
                for try await thumb in stream {
                    if Task.isCancelled { break }
                    if let existingIdx = self.thumbnails.firstIndex(where: { $0.id == thumb.id }) {
                        self.thumbnails[existingIdx] = thumb
                    } else {
                        self.thumbnails.append(thumb)
                    }
                }
            } catch {
                // Ignore cancellation
            }
        }
    }
}
