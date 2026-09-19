import Foundation
import CoreMedia
import AVFoundation
import Combine

/// Master transport state for the timeline engine.
public enum TransportState: Equatable, Sendable {
    case paused
    case playing(rate: Float)
    case scrubbing(originTime: CMTime)
    case seeking(targetTime: CMTime)
}

/// Master clock protocol driving synchronized timeline presentation.
@MainActor
public protocol TimelineClockProtocol: AnyObject {
    var currentTime: CMTime { get }
    var duration: CMTime { get }
    var transportState: TransportState { get }
    var isPlaying: Bool { get }
    var playbackRate: Float { get set }
    var isLoopingEnabled: Bool { get set }
    var loopRange: CMTimeRange? { get set }
    var timePublisher: AnyPublisher<CMTime, Never> { get }

    func attach(player: AVPlayer)
    func detachPlayer()

    func play(rate: Float)
    func pause()
    func togglePlayPause()

    func beginScrubbing()
    func updateScrub(to time: CMTime)
    func endScrubbing(resumePlayback: Bool?)

    func seek(to time: CMTime, tolerance: CMTime) async
    func stepForward(by frameCount: Int, fps: Double)
    func stepBackward(by frameCount: Int, fps: Double)
    func seekForward(by seconds: Double)
    func seekBackward(by seconds: Double)
}

/// Production implementation of TimelineClock maintaining continuous CMTime without frame rounding.
@MainActor
public final class TimelineClock: NSObject, ObservableObject, TimelineClockProtocol {
    public static let canonicalTimescale: CMTimeScale = 600_000

    @Published public private(set) var currentTime: CMTime
    @Published public private(set) var duration: CMTime
    @Published public private(set) var transportState: TransportState = .paused

    @Published public var playbackRate: Float = 1.0 {
        didSet {
            if case .playing = transportState {
                player?.rate = playbackRate
            }
        }
    }

    @Published public var isLoopingEnabled: Bool = false
    @Published public var loopRange: CMTimeRange?
    @Published public var frameRate: Double = 30.0

    public var isPlaying: Bool {
        if case .playing = transportState { return true }
        return false
    }

    private let timeSubject: CurrentValueSubject<CMTime, Never>
    public var timePublisher: AnyPublisher<CMTime, Never> {
        timeSubject.eraseToAnyPublisher()
    }

    private weak var player: AVPlayer?
    private var timeObserverToken: Any?
    private var wasPlayingBeforeScrub: Bool = false
    private var pendingSeekWorkItem: DispatchWorkItem?

    public init(initialTime: CMTime = .zero, duration: CMTime = .zero) {
        let initialClamped = initialTime.isValid && !initialTime.isIndefinite ? initialTime : .zero
        let validDuration = duration.isValid && !duration.isIndefinite ? duration : .zero
        self.currentTime = initialClamped
        self.duration = validDuration
        self.timeSubject = CurrentValueSubject(initialClamped)
        super.init()
    }

    isolated deinit {
        if let token = timeObserverToken, let player = player {
            player.removeTimeObserver(token)
        }
    }

    public func setDuration(_ newDuration: CMTime) {
        guard newDuration.isValid && !newDuration.isIndefinite else { return }
        self.duration = newDuration
    }

    public func attach(player: AVPlayer) {
        detachPlayer()
        self.player = player

        let interval = CMTime(value: 1, timescale: 120) // 120Hz high-frequency tracking
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.handlePlayerTick(time: time)
            }
        }
    }

    public func detachPlayer() {
        if let token = timeObserverToken, let player = player {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        self.player = nil
    }

    private func handlePlayerTick(time: CMTime) {
        guard case .playing = transportState else { return }

        // Loop range check
        if isLoopingEnabled, let loop = loopRange {
            if CMTimeCompare(time, loop.end) >= 0 {
                seekSync(to: loop.start)
                return
            }
        } else if duration > .zero && CMTimeCompare(time, duration) >= 0 {
            pause()
            seekSync(to: duration)
            return
        }

        self.currentTime = time
        self.timeSubject.send(time)
    }

    public func play(rate: Float = 1.0) {
        self.playbackRate = rate
        transportState = .playing(rate: rate)
        if let player = player {
            player.playImmediately(atRate: rate)
        }
    }

    public func pause() {
        transportState = .paused
        player?.pause()
    }

    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play(rate: playbackRate)
        }
    }

    public func beginScrubbing() {
        wasPlayingBeforeScrub = isPlaying
        player?.pause()
        transportState = .scrubbing(originTime: currentTime)
    }

    public func updateScrub(to time: CMTime) {
        guard case .scrubbing = transportState else { return }
        let clampedTime = clampToDuration(time)
        self.currentTime = clampedTime
        self.timeSubject.send(clampedTime)

        // Throttled asynchronous seek to AVPlayer with 30fps tolerance during drag
        pendingSeekWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, let player = self.player else { return }
            let tolerance = CMTime(value: 1, timescale: 30)
            player.seek(to: clampedTime, toleranceBefore: tolerance, toleranceAfter: tolerance)
        }
        pendingSeekWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: workItem)
    }

    public func endScrubbing(resumePlayback: Bool? = nil) {
        guard case .scrubbing = transportState else { return }
        pendingSeekWorkItem?.cancel()
        pendingSeekWorkItem = nil

        let shouldResume = resumePlayback ?? wasPlayingBeforeScrub
        let targetTime = currentTime

        if let player = player {
            player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self else { return }
                    if shouldResume {
                        self.play(rate: self.playbackRate)
                    } else {
                        self.transportState = .paused
                    }
                }
            }
        } else {
            if shouldResume {
                play(rate: playbackRate)
            } else {
                transportState = .paused
            }
        }
    }

    public func seek(to time: CMTime, tolerance: CMTime = .zero) async {
        let clampedTime = clampToDuration(time)
        self.currentTime = clampedTime
        self.timeSubject.send(clampedTime)
        transportState = .seeking(targetTime: clampedTime)

        if let player = player {
            await withCheckedContinuation { continuation in
                player.seek(to: clampedTime, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
                    Task { @MainActor in
                        self?.transportState = .paused
                        continuation.resume()
                    }
                }
            }
        } else {
            self.transportState = .paused
        }
    }

    public func seek(to time: CMTime) {
        Task { @MainActor in
            await seek(to: time, tolerance: .zero)
        }
    }

    private func seekSync(to time: CMTime) {
        self.currentTime = time
        self.timeSubject.send(time)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func stepForward(by frameCount: Int = 1, fps: Double? = nil) {
        let effectiveFps = fps ?? self.frameRate
        let stepSeconds = Double(frameCount) / max(1.0, effectiveFps)
        let stepDuration = CMTime(seconds: stepSeconds, preferredTimescale: Self.canonicalTimescale)
        let newTime = CMTimeAdd(currentTime, stepDuration)
        Task { @MainActor in
            await seek(to: newTime, tolerance: .zero)
        }
    }

    public func stepForward(by frameCount: Int, fps: Double) {
        stepForward(by: frameCount, fps: Optional(fps))
    }

    public func stepBackward(by frameCount: Int = 1, fps: Double? = nil) {
        let effectiveFps = fps ?? self.frameRate
        let stepSeconds = Double(frameCount) / max(1.0, effectiveFps)
        let stepDuration = CMTime(seconds: stepSeconds, preferredTimescale: Self.canonicalTimescale)
        let newTime = CMTimeSubtract(currentTime, stepDuration)
        Task { @MainActor in
            await seek(to: newTime, tolerance: .zero)
        }
    }

    public func stepBackward(by frameCount: Int, fps: Double) {
        stepBackward(by: frameCount, fps: Optional(fps))
    }

    public func seekForward(by seconds: Double = 5.0) {
        let stepDuration = CMTime(seconds: seconds, preferredTimescale: Self.canonicalTimescale)
        let newTime = CMTimeAdd(currentTime, stepDuration)
        Task { @MainActor in
            await seek(to: newTime, tolerance: .zero)
        }
    }

    public func seekBackward(by seconds: Double = 5.0) {
        let stepDuration = CMTime(seconds: seconds, preferredTimescale: Self.canonicalTimescale)
        let newTime = CMTimeSubtract(currentTime, stepDuration)
        Task { @MainActor in
            await seek(to: newTime, tolerance: .zero)
        }
    }

    private func clampToDuration(_ time: CMTime) -> CMTime {
        guard time.isValid && !time.isIndefinite else { return .zero }
        var clamped = time
        if CMTimeCompare(clamped, .zero) < 0 {
            clamped = .zero
        }
        if duration > .zero && CMTimeCompare(clamped, duration) > 0 {
            clamped = duration
        }
        return clamped
    }
}
