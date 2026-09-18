import Testing
import CoreMedia
import AVFoundation
import Combine
import Foundation
@testable import MacDubCore

@Suite("Timeline Master Clock Tests")
@MainActor
struct TimelineClockTests {

    @Test("Continuous CMTime clock maintains exact subframe audio-rate precision")
    func test_continuous_clock_maintains_exact_subframe_precision() async {
        let duration = CMTime(seconds: 60.0, preferredTimescale: TimelineClock.canonicalTimescale)
        let clock = TimelineClock(initialTime: .zero, duration: duration)

        #expect(TimelineClock.canonicalTimescale == 600_000)

        // Subframe continuous timestamp: 1.234567 seconds
        let subframeTime = CMTime(value: 740740, timescale: 600_000) // exactly 1.23456666...s
        await clock.seek(to: subframeTime, tolerance: .zero)

        #expect(CMTimeCompare(clock.currentTime, subframeTime) == 0)
        let seconds = CMTimeGetSeconds(clock.currentTime)
        #expect(abs(seconds - (740740.0 / 600000.0)) < 1e-9)

        // Verify clock did NOT round to 30fps (33.33ms) or 60fps (16.66ms) grid
        let frame30Grid = round(seconds * 30.0) / 30.0
        #expect(abs(seconds - frame30Grid) > 0.001, "Timestamp must not be quantized to 30fps video frame grid")
    }

    @Test("Transport state machine transitions accurately through play, pause, scrub, and seek")
    func test_transport_state_machine_transitions() {
        let duration = CMTime(seconds: 10.0, preferredTimescale: 600_000)
        let clock = TimelineClock(initialTime: .zero, duration: duration)

        // Initial state
        #expect(clock.transportState == .paused)
        #expect(!clock.isPlaying)

        // Play
        clock.play(rate: 1.5)
        #expect(clock.transportState == .playing(rate: 1.5))
        #expect(clock.isPlaying)
        #expect(clock.playbackRate == 1.5)

        // Pause
        clock.pause()
        #expect(clock.transportState == .paused)
        #expect(!clock.isPlaying)

        // Toggle play/pause
        clock.togglePlayPause()
        #expect(clock.isPlaying)
        clock.togglePlayPause()
        #expect(!clock.isPlaying)

        // Scrubbing from 2.0s
        let scrubClock = TimelineClock(
            initialTime: CMTime(seconds: 2.0, preferredTimescale: 600_000),
            duration: duration
        )
        scrubClock.beginScrubbing()
        #expect(scrubClock.transportState == .scrubbing(originTime: CMTime(seconds: 2.0, preferredTimescale: 600_000)))

        scrubClock.updateScrub(to: CMTime(seconds: 3.5, preferredTimescale: 600_000))
        #expect(CMTimeCompare(scrubClock.currentTime, CMTime(seconds: 3.5, preferredTimescale: 600_000)) == 0)

        scrubClock.endScrubbing(resumePlayback: false)
        #expect(scrubClock.transportState == .paused)
        #expect(!scrubClock.isPlaying)
    }

    @Test("Scrubbing preserves pre-scrub playback state when resumePlayback is nil")
    func test_scrub_restores_prior_playback_state() {
        let duration = CMTime(seconds: 10.0, preferredTimescale: 600_000)
        let clock = TimelineClock(initialTime: .zero, duration: duration)

        // Case A: Playing before scrub
        clock.play(rate: 1.0)
        clock.beginScrubbing()
        #expect(clock.transportState == .scrubbing(originTime: .zero))

        clock.updateScrub(to: CMTime(seconds: 1.0, preferredTimescale: 600_000))
        clock.endScrubbing(resumePlayback: nil)
        #expect(clock.isPlaying)
        #expect(clock.transportState == .playing(rate: 1.0))

        // Case B: Paused before scrub
        clock.pause()
        clock.beginScrubbing()
        clock.updateScrub(to: CMTime(seconds: 2.0, preferredTimescale: 600_000))
        clock.endScrubbing(resumePlayback: nil)
        #expect(!clock.isPlaying)
        #expect(clock.transportState == .paused)
    }

    @Test("Asynchronous seek updates currentTime and settles in paused state")
    func test_asynchronous_seek() async {
        let duration = CMTime(seconds: 20.0, preferredTimescale: 600_000)
        let clock = TimelineClock(initialTime: .zero, duration: duration)

        let target = CMTime(seconds: 7.89, preferredTimescale: 600_000)
        await clock.seek(to: target, tolerance: .zero)

        #expect(CMTimeCompare(clock.currentTime, target) == 0)
        #expect(clock.transportState == .paused)
    }

    @Test("Step forward and backward adjust playhead by exact frame durations")
    func test_step_forward_and_backward() async {
        let duration = CMTime(seconds: 10.0, preferredTimescale: 600_000)
        let clock = TimelineClock(initialTime: CMTime(seconds: 2.0, preferredTimescale: 600_000), duration: duration)

        clock.stepForward(by: 1, fps: 30.0)
        // Give MainActor task a micro-yield to execute async seek
        await Task.yield()
        let expectedForward = CMTime(seconds: 2.0 + (1.0 / 30.0), preferredTimescale: 600_000)
        #expect(abs(CMTimeGetSeconds(clock.currentTime) - CMTimeGetSeconds(expectedForward)) < 1e-5)

        clock.stepBackward(by: 2, fps: 30.0)
        await Task.yield()
        let expectedBackward = CMTime(seconds: 2.0 - (1.0 / 30.0), preferredTimescale: 600_000)
        #expect(abs(CMTimeGetSeconds(clock.currentTime) - CMTimeGetSeconds(expectedBackward)) < 1e-5)
    }

    @Test("Seek forward and backward adjust playhead by seconds rather than frames")
    func test_seek_forward_and_backward_seconds() async {
        let duration = CMTime(seconds: 20.0, preferredTimescale: 600_000)
        let clock = TimelineClock(initialTime: CMTime(seconds: 8.0, preferredTimescale: 600_000), duration: duration)

        clock.seekForward(by: 5.0)
        await Task.yield()
        #expect(abs(CMTimeGetSeconds(clock.currentTime) - 13.0) < 1e-5)

        clock.seekBackward(by: 5.0)
        await Task.yield()
        #expect(abs(CMTimeGetSeconds(clock.currentTime) - 8.0) < 1e-5)

        // Clamping to boundaries
        clock.seekBackward(by: 10.0)
        await Task.yield()
        #expect(CMTimeCompare(clock.currentTime, .zero) == 0)

        clock.seekForward(by: 25.0)
        await Task.yield()
        #expect(CMTimeCompare(clock.currentTime, duration) == 0)
    }

    @Test("Duration and negative time clamping protect boundaries")
    func test_clamping_behavior() async {
        let duration = CMTime(seconds: 5.0, preferredTimescale: 600_000)
        let clock = TimelineClock(initialTime: .zero, duration: duration)

        // Scrub past end
        clock.beginScrubbing()
        clock.updateScrub(to: CMTime(seconds: 8.0, preferredTimescale: 600_000))
        #expect(CMTimeCompare(clock.currentTime, duration) == 0)

        // Scrub before start
        clock.updateScrub(to: CMTime(seconds: -3.0, preferredTimescale: 600_000))
        #expect(CMTimeCompare(clock.currentTime, .zero) == 0)
        clock.endScrubbing(resumePlayback: false)

        // Seek past end
        await clock.seek(to: CMTime(seconds: 100.0, preferredTimescale: 600_000))
        #expect(CMTimeCompare(clock.currentTime, duration) == 0)

        // Seek before zero
        await clock.seek(to: CMTime(seconds: -10.0, preferredTimescale: 600_000))
        #expect(CMTimeCompare(clock.currentTime, .zero) == 0)
    }

    @Test("Combine timePublisher emits values on playhead changes")
    func test_combine_time_publisher_emissions() {
        let duration = CMTime(seconds: 10.0, preferredTimescale: 600_000)
        let clock = TimelineClock(initialTime: .zero, duration: duration)

        var receivedTimes: [Double] = []
        var cancellables = Set<AnyCancellable>()

        clock.timePublisher
            .sink { time in
                receivedTimes.append(CMTimeGetSeconds(time))
            }
            .store(in: &cancellables)

        #expect(receivedTimes.count == 1)
        #expect(receivedTimes[0] == 0.0)

        clock.beginScrubbing()
        clock.updateScrub(to: CMTime(seconds: 1.5, preferredTimescale: 600_000))
        clock.updateScrub(to: CMTime(seconds: 3.0, preferredTimescale: 600_000))
        clock.endScrubbing(resumePlayback: false)

        #expect(receivedTimes.contains(1.5))
        #expect(receivedTimes.contains(3.0))
    }

    @Test("Attach and detach AVPlayer lifecycle functions safely")
    func test_attach_and_detach_avplayer() {
        let clock = TimelineClock(initialTime: .zero, duration: CMTime(seconds: 10.0, preferredTimescale: 600_000))
        let player = AVPlayer()

        clock.attach(player: player)
        clock.detachPlayer()
        // Double detach must be safe and idempotent
        clock.detachPlayer()
    }

    @Test("SetDuration updates clock duration properly")
    func test_set_duration() {
        let clock = TimelineClock(initialTime: .zero, duration: .zero)
        #expect(CMTimeCompare(clock.duration, .zero) == 0)

        let newDur = CMTime(seconds: 15.0, preferredTimescale: 600_000)
        clock.setDuration(newDur)
        #expect(CMTimeCompare(clock.duration, newDur) == 0)

        // Invalid duration ignored
        clock.setDuration(.invalid)
        #expect(CMTimeCompare(clock.duration, newDur) == 0)
    }

    @Test("Frame stepping adapts to source frame rates (24, 30, 60 fps)")
    func test_frame_stepping_at_source_rates_24_30_60() async {
        let duration = CMTime(seconds: 10.0, preferredTimescale: 600_000)

        // 1. 24 fps: 1 frame = 1/24s = 0.041666...s (25,000 / 600,000)
        let clock24 = TimelineClock(initialTime: .zero, duration: duration)
        clock24.frameRate = 24.0
        clock24.stepForward(by: 1)
        // allow async seek
        try? await Task.sleep(nanoseconds: 20_000_000)
        let sec24 = CMTimeGetSeconds(clock24.currentTime)
        #expect(abs(sec24 - (1.0 / 24.0)) < 1e-4, "Stepping at 24fps must advance by 1/24s")
        clock24.stepBackward(by: 1)
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(abs(CMTimeGetSeconds(clock24.currentTime)) < 1e-4, "Stepping backward must return to 0s")

        // 2. 30 fps: 1 frame = 1/30s = 0.033333...s (20,000 / 600,000)
        let clock30 = TimelineClock(initialTime: .zero, duration: duration)
        clock30.frameRate = 30.0
        clock30.stepForward(by: 1)
        try? await Task.sleep(nanoseconds: 20_000_000)
        let sec30 = CMTimeGetSeconds(clock30.currentTime)
        #expect(abs(sec30 - (1.0 / 30.0)) < 1e-4, "Stepping at 30fps must advance by 1/30s")

        // 3. 60 fps: 1 frame = 1/60s = 0.016666...s (10,000 / 600,000)
        let clock60 = TimelineClock(initialTime: .zero, duration: duration)
        clock60.frameRate = 60.0
        clock60.stepForward(by: 1)
        try? await Task.sleep(nanoseconds: 20_000_000)
        let sec60 = CMTimeGetSeconds(clock60.currentTime)
        #expect(abs(sec60 - (1.0 / 60.0)) < 1e-4, "Stepping at 60fps must advance by 1/60s")
    }
}
