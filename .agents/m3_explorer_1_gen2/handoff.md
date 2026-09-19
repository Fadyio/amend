# Architectural Handoff Report: Milestone 3 — Timeline Engine & Visual Presentation

**Agent**: `m3_explorer_1_gen2`  
**Milestone**: Milestone 3 (Timeline Engine & Visual Presentation)  
**Target Working Directory**: `/Users/fady/Dev/amend/.agents/m3_explorer_1_gen2`  
**Date**: 2026-09-17  

---

## 1. Observation

### 1.1 Authoritative Requirements & Codebase State
1. **Requirements (R1 & Acceptance Criteria)**:
   - In `/Users/fady/Dev/amend/ORIGINAL_REQUEST.md`:
     - Line 29–30: *"Build a native macOS video viewer and horizontal timeline driven strictly by CMTime and CMTimeRange with synchronized visual layers: SMPTE timecode ruler using SwiftTimecode for drop-frame/standard frame rate handling."*
     - Line 34–35: *"Horizontal zoom controlled by pixelsPerSecond with a continuous CMTime-based draggable playhead providing frame-accurate video seeking and audio-resolution Cue boundary representation. Maintain a strict distinction between timelineTime (high-resolution CMTime) and displayTimecode (frame-quantized SMPTE representation). Never round internal Cue boundaries to video frames."*
     - Line 103–104: *"Draggable playhead tracks continuous CMTime and maintains frame-accurate video seeking. Internal Cue boundaries maintain exact audio-rate timestamps and are never rounded to video frames."*
2. **Project Blueprint & Layout**:
   - In `/Users/fady/Dev/amend/.agents/orchestrator_9/PROJECT.md`:
     - Lines 128–132 list target files under `Sources/AmendCore/Timeline/`:
       - `TimelineClock.swift`
       - `SMPTERulerFormatter.swift`
       - `FilmstripGenerator.swift`
       - `WaveformExtractor.swift`
     - Investigation of `/Users/fady/Dev/amend/Sources/AmendCore/` reveals that `Timeline/` does not yet exist. Milestones M1 and M2 (`Models/`, `Storage/`, `Composition/`) are implemented and verified.
3. **Package Dependencies & Integration**:
   - In `/Users/fady/Dev/amend/Package.swift`:
     - Lines 14–16 & 22–24:
       ```swift
       .package(url: "https://github.com/dmrschmidt/DSWaveformImage.git", from: "14.5.0"),
       .package(url: "https://github.com/orchetect/swift-timecode.git", from: "3.1.4"),
       ```
       Target `AmendCore` already links products `.product(name: "SwiftTimecodeCore", package: "swift-timecode")` and `.product(name: "SwiftTimecodeAV", package: "swift-timecode")`.
   - Inspection of `.build/checkouts/swift-timecode/Sources/SwiftTimecodeCore/`:
     - `Timecode Rational CMTime.swift` (lines 58–71): provides `timecode.cmTimeValue: CMTime` and static constructors `TimecodeSourceValue.cmTime(_:)`.
     - `Timecode FrameCount.swift` (lines 150–232): provides drop-frame and non-drop-frame calculation algorithms between frame indices and SMPTE components (`dd:hh:mm:ss:ff`).
     - `TimecodeFrameRate.swift` (lines 54–100): defines standard frame rates: `.fps23_976`, `.fps24`, `.fps25`, `.fps29_97`, `.fps29_97d`, `.fps30`, `.fps59_94`, `.fps59_94d`, `.fps60`.
4. **Existing Domain Models**:
   - In `/Users/fady/Dev/amend/Sources/AmendCore/Models/Cue.swift`:
     - Line 6: `public let timeRange: CMTimeRange // Immutable slot boundaries`
     - Lines 31–33: `public var start: CMTime { timeRange.start }`, `public var duration: CMTime { timeRange.duration }`, `public var end: CMTime { timeRange.end }`
     - Lines 100–102: `public func contains(time: CMTime) -> Bool { CMTimeCompare(time, timeRange.start) >= 0 && CMTimeCompare(time, timeRange.end) < 0 }`
   - In `/Users/fady/Dev/amend/Sources/AmendCore/Models/CMTime+Codable.swift`: `CMTime` and `CMTimeRange` have retroactive `Codable` conformances.

---

## 2. Logic Chain

### 2.1 TimelineClock Architecture

#### A. Continuous Audio-Rate Core Media Time (`CMTime`) Master Clock
- **Observation**: Video editing applications that store playhead state as integer frame numbers (e.g., frame 142 at 30 fps) or floating point seconds subject timestamps to quantization errors ($1/30\text{ s} \approx 33.33\text{ ms}$).
- **Deduction**: In `amend`, audio operations operate at audio sample precision ($1/48000\text{ s} \approx 0.0208\text{ ms}$). If the playhead or cue boundaries were rounded to video frame intervals, audio cue splitting and boundary alignment would suffer accumulated drift of up to $16.67\text{ ms}$ per edit.
- **Architectural Solution**:
  - `TimelineClock` maintains its master playhead position strictly as `currentTime: CMTime`.
  - The canonical timescale for `TimelineClock` calculations should be `600_000` (or the native audio track timescale, typically `48_000`).
    - *Mathematical justification for 600,000*: It is the lowest common multiple of all standard screen-recording and broadcast frame rates and their NTSC fractional pull-downs:
      - $600{,}000 / 24 = 25{,}000$ (exact integer)
      - $600{,}000 / 25 = 24{,}000$ (exact integer)
      - $600{,}000 / 30 = 20{,}000$ (exact integer)
      - $600{,}000 / 50 = 12{,}000$ (exact integer)
      - $600{,}000 / 60 = 10{,}000$ (exact integer)
      - $600{,}000 \times 1001 / 24{,}000 = 25{,}025$ (exact integer for 23.976 fps)
      - $600{,}000 \times 1001 / 30{,}000 = 20{,}020$ (exact integer for 29.97 fps)
      - $600{,}000 \times 1001 / 60{,}000 = 10{,}010$ (exact integer for 59.94 fps)
  - Video frame quantization is strictly restricted to display formatting (`SMPTERulerFormatter`), guaranteeing **zero synchronization drift** at the clock engine level.

#### B. Sub-Frame Playhead Scrubbing at Continuous Resolution
- **Observation**: During mouse drag or trackpad scrubbing, drag events arrive at display refresh rates (60 Hz or 120 Hz ProMotion).
- **Deduction**: Dispathing synchronous `AVPlayer.seek(to:time, toleranceBefore:.zero, toleranceAfter:.zero)` on every mouse move chokes AVFoundation's hardware video decoder queue, causing severe UI hitching. Conversely, quantizing scrub positions to frame boundaries destroys sub-frame audio editing precision.
- **Architectural Solution**:
  - **Dual-Path Scrubbing Pipeline**:
    1. **Immediate High-Frequency Path (UI/Playhead)**: Direct mapping from cursor pixel offset $x$ to continuous time $t = x / \text{pixelsPerSecond}$ stored as `CMTime(seconds: t, preferredTimescale: 600_000)`. Published immediately to SwiftUI `@Observable` state.
    2. **Decoupled/Coalesced Seek Path (AVPlayer Video Engine)**:
       - When scrubbing rapidly, issue asynchronous seeks with loose tolerance (`toleranceBefore: CMTime(value: 1, timescale: 30), toleranceAfter: CMTime(value: 1, timescale: 30)`), coalescing intermediate points and canceling pending seeks.
       - When scrubbing settles or mouse-up occurs (`endScrubbing`), execute a single zero-tolerance seek (`toleranceBefore: .zero, toleranceAfter: .zero`) to guarantee exact frame-accurate video presentation.

#### C. Transport State Machine
The transport engine requires a formal finite-state machine (FSM) to prevent race conditions between player time observers, user scrub gestures, and programmatic seeks:
- **States**:
  1. `.paused`: Clock is stationary at `currentTime`.
  2. `.playing(rate: Float)`: AVPlayer is playing at `rate` (normally 1.0); clock advances in lockstep with the AVPlayer hardware audio timebase.
  3. `.scrubbing(originTime: CMTime, preScrubState: TransportPreScrubState)`: User is actively dragging playhead. AVPlayer is paused or tracking scrub seeks.
  4. `.seeking(targetTime: CMTime, resumeState: TransportResumeState)`: Programmatic seek in progress (e.g. clicking a Cue to jump).
- **Transitions**:
  - `play(rate: Float)`: `.paused` $\to$ `.playing(rate:)`
  - `pause()`: `.playing` $\to$ `.paused`
  - `beginScrubbing()`: Saves whether playback was active; pauses AVPlayer; enters `.scrubbing`.
  - `updateScrub(to: CMTime)`: Valid only in `.scrubbing`; updates playhead and drives throttled seek.
  - `endScrubbing(resumePlayback: Bool?)`: Exits `.scrubbing`; performs final exact seek; resumes playback if requested/configured, or transitions to `.paused`.
  - `seek(to: CMTime, exact: Bool)`: Transitions to `.seeking`, executes AVPlayer seek with completion handler, transitions to destination resume state.

#### D. Rate Control, Looping, and AVPlayer Synchronization
- **AVPlayer Clock Coupling**:
  - During playback, `AVPlayer`'s audio-hardware-driven timebase is the authoritative ground truth.
  - `TimelineClock` attaches an `addPeriodicTimeObserver(forInterval:queue:using:)` at 60 Hz or 120 Hz (`CMTime(value: 1, timescale: 120)` on `DispatchQueue.main`).
  - Between observer callbacks, UI animation can smoothly interpolate using display links without drifting from the master player timebase.
- **Looping Mechanics**:
  - `loopRange: CMTimeRange?`: Defaults to nil (or entire asset `[CMTime.zero, totalDuration)`).
  - When active cue auditioning is engaged, `loopRange` is set to `cue.timeRange`.
  - In the time observer callback: if `currentTime >= loopRange.end`, `TimelineClock` immediately invokes `seek(to: loopRange.start, exact: true)` and continues playback.

---

### 2.2 SMPTERulerFormatter Architecture

#### A. Conversion Between CMTime and SMPTE Timecode
- **Observation**: SMPTE timecode represents time as `Hours : Minutes : Seconds : Frames` (or `Hours : Minutes : Seconds ; Frames` for drop-frame).
- **Deduction**: `SwiftTimecodeCore` provides direct, production-hardened support for `Timecode` backed by `CMTime`:
  - `Timecode(.cmTime(time), at: frameRate)`
  - `timecode.cmTimeValue`
  - `timecode.stringValue(format:)`
- **Architectural Solution**:
  - Wrap `SwiftTimecodeCore` within `SMPTERulerFormatter` to provide zero-allocation, cached conversions for the timeline ruler and UI badges.

#### B. Frame-Rate Awareness
The formatter must support:
- `23.976 fps` (`TimecodeFrameRate.fps23_976`): $24 / 1.001$, standard film transfer. Non-drop.
- `24 fps` (`TimecodeFrameRate.fps24`): Standard cinema/film. Non-drop.
- `25 fps` (`TimecodeFrameRate.fps25`): PAL broadcast standard. Non-drop.
- `29.97 fps NDF` (`TimecodeFrameRate.fps29_97`): $30 / 1.001$, NTSC non-drop frame.
- `29.97 fps DF` (`TimecodeFrameRate.fps29_97d`): $30 / 1.001$, NTSC drop frame. Uses `;` separator.
- `30 fps` (`TimecodeFrameRate.fps30`): Integer standard, common in screen captures. Non-drop.
- `59.94 fps NDF` (`TimecodeFrameRate.fps59_94`): $60 / 1.001$, HD broadcast non-drop frame.
- `59.94 fps DF` (`TimecodeFrameRate.fps59_94d`): $60 / 1.001$, HD broadcast drop frame. Uses `;` separator.
- `60 fps` (`TimecodeFrameRate.fps60`): Integer standard, high-rate macOS screen recordings (Retina). Non-drop.

#### C. Mathematical Drop-Frame Calculation Algorithms
- **Origin of Drop-Frame**:
  Because NTSC color runs at $30{,}000 / 1{,}001 \approx 29.97003\text{ fps}$, counting 30 frames per second creates an error of $30 - 29.97003 = 0.02997\text{ frames/sec}$. Over 1 hour (3600 seconds), this accumulates to $0.02997 \times 3600 = 107.892\text{ frames}$ ($\approx 3.6\text{ seconds}$ of real-time drift).
- **The Drop Algorithm**:
  - At **29.97 DF**: Skip frame numbers `00` and `01` at the start of every minute, **except** minutes that are multiples of 10 (`00`, `10`, `20`, `30`, `40`, `50`).
    - Number of non-decade minutes per hour: $60 - 6 = 54$.
    - Total dropped frame numbers: $54 \times 2 = 108\text{ frames/hour}$.
    - Residual error: $108 - 107.892 = 0.108\text{ frames/hour}$ ($\approx 3.6\text{ ms/hour}$, $< 1\text{ frame in 9 hours}$).
  - At **59.94 DF**: Skip frame numbers `00`, `01`, `02`, and `03` (4 frames) at the start of every minute, except minutes that are multiples of 10.
    - Total dropped frame numbers: $54 \times 4 = 216\text{ frames/hour}$.
- **Mathematical Formulations**:
  - **SMPTE Components $(H, M, S, F) \to$ Total Elapsed Frames $N$**:
    $$M_{\text{total}} = H \times 60 + M$$
    $$N_{\text{base}} = (M_{\text{total}} \times 60 + S) \times F_{\text{nom}} + F$$
    $$\text{dropped} = D \times \left(M_{\text{total}} - \left\lfloor \frac{M_{\text{total}}}{10} \right\rfloor\right)$$
    $$N = N_{\text{base}} - \text{dropped}$$
    *(where $F_{\text{nom}} = 30$ for 29.97d and $60$ for 59.94d; $D = 2$ for 29.97d and $4$ for 59.94d)*.
  - **Total Elapsed Frames $N \to$ SMPTE Components $(H, M, S, F)$**:
    Let $F_{10\text{m}} = 600 \times F_{\text{nom}} - 9 \times D$ (17,982 frames for 29.97d; 35,964 for 59.94d).
    $$d = \lfloor N / F_{10\text{m}} \rfloor$$
    $$m = N \pmod{F_{10\text{m}}}$$
    $$f = \max(0, m - D)$$
    $$N' = N + 9 \times D \times d + D \times \left\lfloor \frac{f}{(F_{10\text{m}} - D) / 10} \right\rfloor$$
    $$F = N' \pmod{F_{\text{nom}}}$$
    $$S = \lfloor N' / F_{\text{nom}} \rfloor \pmod{60}$$
    $$M = \lfloor N' / (F_{\text{nom}} \times 60) \rfloor \pmod{60}$$
    $$H = \lfloor N' / (F_{\text{nom}} \times 3600) \rfloor$$

#### D. Dynamic Ruler Tick Subdivision and Labeling Across Zoom Scales
- **Zoom Geometry**:
  Horizontal zoom is represented by `pixelsPerSecond: Double` (range: $10.0\text{ px/s}$ to $2000.0\text{ px/s}$).
  Target distance between major labels: $W_{\text{major}} \approx 80\text{ to }120\text{ points}$.
- **Subdivision Hierarchy (Calibrated Interval Ladder)**:
  Target time interval: $\Delta t_{\text{ideal}} = W_{\text{major}} / \text{pixelsPerSecond}$.
  The ruler formatter selects the closest canonical interval step:
  - **Hours Tier**: `3600s`, `1800s`, `600s`, `300s`
  - **Minutes Tier**: `60s`, `30s`, `15s`, `10s`, `5s`
  - **Seconds Tier**: `2s`, `1s`, `0.5s`
  - **Frames Tier**: `15 frames`, `10 frames`, `5 frames`, `2 frames`, `1 frame` ($1 / fps$)
  - **Sub-Frames Tier**: `0.5 frame`, `0.25 frame` (or $10\text{ms}$, $1\text{ms}$)
- **Minor Tick Subdivision**:
  Each major interval defines its internal subdivision factor $K$:
  - 1 minute ($60\text{s}$): 6 subdivisions of $10\text{s}$ (or 12 of $5\text{s}$).
  - 1 second ($1\text{s}$): divided into frames ($24$, $25$, $30$, or $60$ ticks, with medium ticks at half-seconds).
  - 1 frame: divided into 2 or 4 sub-frame ticks.
- **Viewport Culling**:
  Only ticks within the visible viewport bounds $[x_{\text{min}} - \text{margin}, x_{\text{max}} + \text{margin}]$ are instantiated and rendered:
  $$t_{\text{start}} = \max(0, (x_{\text{min}} - \text{margin}) / \text{pps})$$
  $$t_{\text{end}} = \min(T_{\text{total}}, (x_{\text{max}} + \text{margin}) / \text{pps})$$
  Ensures $O(\text{visible\_ticks})$ performance rather than $O(\text{timeline\_duration})$.

---

### 2.3 Magnetic Playhead Snapping

#### A. Snapping Targets
- The playhead can magnetically snap to:
  1. Every cue boundary: `cue.timeRange.start` (in-point) and `cue.timeRange.end` (out-point) for all $N$ cues.
  2. Timeline origin: `CMTime.zero`.
  3. Timeline end: `projectMetadata.totalDuration`.
  4. Loop boundaries: `loopRange.start` and `loopRange.end` (if set).

#### B. Mathematical Conversion: Pixel Threshold $\leftrightarrow$ CMTime Tolerance
- Configurable pixel threshold: $D_{\text{snap}} = 8.0\text{ px}$ (default).
- At zoom level `pixelsPerSecond` (pps):
  $$\Delta t_{\text{snap}} = \frac{D_{\text{snap}}}{\text{pixelsPerSecond}}\text{ seconds}$$
  $$\Delta t_{\text{snap, CMTime}} = \text{CMTime}(seconds: \Delta t_{\text{snap}}, preferredTimescale: 600{,}000)$$
- **Numerical verification**:
  - At $20\text{ px/s}$ (overview zoom): $\Delta t_{\text{snap}} = 8 / 20 = 0.400\text{ s}$ ($400\text{ ms}$).
  - At $100\text{ px/s}$ (normal editing): $\Delta t_{\text{snap}} = 8 / 100 = 0.080\text{ s}$ ($80\text{ ms}$).
  - At $500\text{ px/s}$ (detailed cue editing): $\Delta t_{\text{snap}} = 8 / 500 = 0.016\text{ s}$ ($16\text{ ms} \approx 1\text{ video frame at 60fps}$).
  - At $2000\text{ px/s}$ (audio sample editing): $\Delta t_{\text{snap}} = 8 / 2000 = 0.004\text{ s}$ ($4\text{ ms}$).
- **Result**: Visual snapping distance remains constant ($8\text{ pixels}$ on screen) regardless of zoom level, providing consistent physical feel.

#### C. Snapping Hysteresis & Release Mechanics
- **The Naive Snapping Problem**:
  Symmetric snapping without hysteresis causes a "sticky trap" or visual stutter: when dragging across a boundary, the playhead abruptly locks at the boundary, and as soon as the cursor crosses $8.01\text{ px}$, it jumps $8\text{ px}$ forward. Moreover, making fine adjustments within $8\text{ px}$ of a boundary is impossible without zooming in.
- **Dual-Threshold Hysteresis State Machine**:
  1. **Acquisition Threshold**: $D_{\text{acquire}} = 8.0\text{ px}$.
     - When playhead is **unsnapped**: if $|x_{\text{cursor}} - x_{\text{target}}| \le D_{\text{acquire}}$, snap playhead to $t_{\text{target}}$.
     - Record `activeSnapTarget = target` and playhead enters **snapped state**.
     - Emit AppKit alignment haptic: `NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)`.
  2. **Release / Breakaway Threshold**: $D_{\text{release}} = 14.0\text{ px}$ ($1.75 \times D_{\text{acquire}}$).
     - When playhead is **snapped** to $t_{\text{target}}$: the playhead remains locked at $t_{\text{target}}$ as long as $|x_{\text{cursor}} - x_{\text{target}}| \le D_{\text{release}}$.
     - Once $|x_{\text{cursor}} - x_{\text{target}}| > D_{\text{release}}$, the snap breaks away. Playhead resumes continuous free tracking of $x_{\text{cursor}}$.
  3. **Modifier Key Bypass**:
     - Holding `Option` (or `Command`) temporarily forces $D_{\text{snap}} = 0$, completely disabling snapping for precision placement right next to boundaries.

---

## 3. Caveats

1. **AVPlayer Hardware Audio Clock Ownership**:
   - In AVFoundation, `AVPlayer` synchronizes video frames to its underlying CoreAudio hardware device clock. Attempting to force AVPlayer to advance at artificial clock ticks via rapid seeks during normal playback causes audio dropouts. Therefore, during `.playing`, `AVPlayer` is the clock master, while during `.paused` or `.scrubbing`, `TimelineClock` is the master.
2. **Variable Frame Rate (VFR) Screen Recordings**:
   - Screen recordings captured via QuickTime or macOS ScreenCaptureKit often have variable frame rates (e.g. dropping to 10 fps during static screens and surging to 60 fps during motion).
   - *Mitigation*: The master clock must remain continuous audio-rate `CMTime`. `SMPTERulerFormatter` should format display timecode using the nominal container frame rate (e.g. 60 fps or 30 fps) extracted by `SwiftTimecodeAV` from the video track.
3. **Swift Concurrency & MainActor Isolation**:
   - `TimelineClock` publishes state to UI views and interacts with `AVPlayer` (which must be accessed on the main thread). Therefore, `TimelineClock` should be annotated `@MainActor` with `@Observable` (or `ObservableObject`), while background caching and thumbnail decoding remain on background actors.
4. **Scope Demarcation**:
   - Filmstrip thumbnail generation (`FilmstripGenerator`) and audio waveform extraction (`WaveformExtractor`) are companion components in Milestone 3. Their interaction with `TimelineClock` and `SMPTERulerFormatter` is coordinated through `pixelsPerSecond` and `visibleTimeRange`.

---

## 4. Conclusion & Proposed Architecture

### 4.1 Concrete Swift API Signatures & Data Structures

Below are the recommended production-grade Swift APIs to be implemented in `Sources/AmendCore/Timeline/`:

#### 1. `TimelineClock.swift`
```swift
import Foundation
import CoreMedia
import AVFoundation

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
    
    func attach(player: AVPlayer)
    func detachPlayer()
    
    func play(rate: Float)
    func pause()
    func togglePlayPause()
    
    func beginScrubbing()
    func updateScrub(to time: CMTime)
    func endScrubbing(resumePlayback: Bool?)
    
    func seek(to time: CMTime, tolerance: CMTime) async
    func stepForward(by frameCount: Int)
    func stepBackward(by frameCount: Int)
}

/// Production implementation of TimelineClock maintaining continuous CMTime without frame rounding.
@Observable
@MainActor
public final class TimelineClock: TimelineClockProtocol {
    public static let canonicalTimescale: CMTimeScale = 600_000
    
    public private(set) var currentTime: CMTime
    public private(set) var duration: CMTime
    public private(set) var transportState: TransportState = .paused
    
    public var playbackRate: Float = 1.0 {
        didSet {
            if case .playing = transportState {
                player?.rate = playbackRate
            }
        }
    }
    
    public var isLoopingEnabled: Bool = false
    public var loopRange: CMTimeRange?
    
    public var isPlaying: Bool {
        if case .playing = transportState { return true }
        return false
    }
    
    private weak var player: AVPlayer?
    private var timeObserverToken: Any?
    private var wasPlayingBeforeScrub: Bool = false
    private var pendingSeekWorkItem: DispatchWorkItem?
    
    public init(initialTime: CMTime = .zero, duration: CMTime = .zero) {
        self.currentTime = initialTime
        self.duration = duration
    }
    
    deinit {
        // detach observer
    }
    
    public func attach(player: AVPlayer) {
        detachPlayer()
        self.player = player
        
        let interval = CMTime(value: 1, timescale: 120) // 120Hz tracking
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            self?.handlePlayerTick(time: time)
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
    }
    
    public func play(rate: Float = 1.0) {
        self.playbackRate = rate
        transportState = .playing(rate: rate)
        player?.playImmediately(atRate: rate)
    }
    
    public func pause() {
        transportState = .paused
        player?.pause()
    }
    
    public func togglePlayPause() {
        if isPlaying { pause() } else { play(rate: playbackRate) }
    }
    
    public func beginScrubbing() {
        wasPlayingBeforeScrub = isPlaying
        player?.pause()
        transportState = .scrubbing(originTime: currentTime)
    }
    
    public func updateScrub(to time: CMTime) {
        guard case .scrubbing = transportState else { return }
        let clampedTime = CMTimeClampToRange(time, range: CMTimeRange(start: .zero, duration: duration))
        self.currentTime = clampedTime
        
        // Throttled asynchronous seek to AVPlayer
        pendingSeekWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            let tolerance = CMTime(value: 1, timescale: 30)
            self?.player?.seek(to: clampedTime, toleranceBefore: tolerance, toleranceAfter: tolerance)
        }
        pendingSeekWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: workItem)
    }
    
    public func endScrubbing(resumePlayback: Bool? = nil) {
        guard case .scrubbing = transportState else { return }
        pendingSeekWorkItem?.cancel()
        
        let shouldResume = resumePlayback ?? wasPlayingBeforeScrub
        let targetTime = currentTime
        
        player?.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self = self else { return }
            if shouldResume {
                self.play(rate: self.playbackRate)
            } else {
                self.transportState = .paused
            }
        }
    }
    
    public func seek(to time: CMTime, tolerance: CMTime = .zero) async {
        let clampedTime = CMTimeClampToRange(time, range: CMTimeRange(start: .zero, duration: duration))
        self.currentTime = clampedTime
        transportState = .seeking(targetTime: clampedTime)
        
        await withCheckedContinuation { continuation in
            player?.seek(to: clampedTime, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
                guard let self = self else {
                    continuation.resume()
                    return
                }
                self.transportState = .paused
                continuation.resume()
            }
        }
    }
    
    private func seekSync(to time: CMTime) {
        self.currentTime = time
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    
    public func stepForward(by frameCount: Int = 1) {
        // Advances by exact frame interval
    }
    
    public func stepBackward(by frameCount: Int = 1) {
        // Steps back by exact frame interval
    }
}
```

#### 2. `SMPTERulerFormatter.swift`
```swift
import Foundation
import CoreMedia
import SwiftTimecodeCore

/// Model representing an individual tick mark along the timeline ruler.
public struct RulerTick: Identifiable, Equatable, Sendable {
    public let id: String
    public let time: CMTime
    public let pixelOffset: CGFloat
    public let isMajor: Bool
    public let label: String?
    
    public init(id: String, time: CMTime, pixelOffset: CGFloat, isMajor: Bool, label: String?) {
        self.id = id
        self.time = time
        self.pixelOffset = pixelOffset
        self.isMajor = isMajor
        self.label = label
    }
}

/// Formatter providing frame-rate aware SMPTE conversions and dynamic ruler tick generation.
public final class SMPTERulerFormatter: Sendable {
    public let frameRate: TimecodeFrameRate
    
    public init(frameRate: TimecodeFrameRate = .fps30) {
        self.frameRate = frameRate
    }
    
    /// Converts a continuous CMTime into a SMPTE timecode string (e.g. "00:01:23:15" or "00:01:23;15").
    public func string(from time: CMTime, includeSubFrames: Bool = false) -> String {
        do {
            let tc = try Timecode(.cmTime(time), at: frameRate)
            let format: Timecode.StringFormat = includeSubFrames ? [.showSubFrames] : []
            return tc.stringValue(format: format)
        } catch {
            return "00:00:00:00"
        }
    }
    
    /// Parses a SMPTE timecode string back into an exact CMTime.
    public func time(from timecodeString: String) throws -> CMTime {
        let tc = try Timecode(.string(timecodeString), at: frameRate)
        return tc.cmTimeValue
    }
    
    /// Computes dynamic tick interval based on zoom scale.
    public func majorInterval(for pixelsPerSecond: Double, targetPixelSpacing: CGFloat = 100.0) -> TimeInterval {
        let idealTime = Double(targetPixelSpacing) / pixelsPerSecond
        let ladder: [TimeInterval] = [
            3600.0, 1800.0, 600.0, 300.0, 60.0, 30.0, 15.0, 10.0, 5.0, 2.0, 1.0, 0.5,
            1.0 / frameRate.frameRateForRealTimeCalculation * 15,
            1.0 / frameRate.frameRateForRealTimeCalculation * 5,
            1.0 / frameRate.frameRateForRealTimeCalculation
        ]
        
        for step in ladder.reversed() {
            if step >= idealTime {
                return step
            }
        }
        return ladder.first ?? 1.0
    }
    
    /// Generates visible ruler ticks culled to the current scroll viewport.
    public func generateTicks(
        visibleRect: CGRect,
        pixelsPerSecond: Double,
        totalDuration: CMTime
    ) -> [RulerTick] {
        var ticks: [RulerTick] = []
        let interval = majorInterval(for: pixelsPerSecond)
        guard interval > 0 else { return [] }
        
        let startSec = max(0.0, Double(visibleRect.minX) / pixelsPerSecond)
        let endSec = min(totalDuration.seconds, Double(visibleRect.maxX) / pixelsPerSecond)
        
        let firstIndex = Int(floor(startSec / interval))
        let lastIndex = Int(ceil(endSec / interval))
        
        for i in firstIndex...lastIndex {
            let tickSec = Double(i) * interval
            if tickSec > totalDuration.seconds { break }
            
            let tickTime = CMTime(seconds: tickSec, preferredTimescale: 600_000)
            let pixelOffset = CGFloat(tickSec * pixelsPerSecond)
            let labelText = string(from: tickTime)
            
            ticks.append(RulerTick(
                id: "major_\(i)",
                time: tickTime,
                pixelOffset: pixelOffset,
                isMajor: true,
                label: labelText
            ))
        }
        
        return ticks
    }
}
```

#### 3. `PlayheadSnapper.swift`
```swift
import Foundation
import CoreMedia

/// Represents the magnetic snapping result for playhead scrubbing.
public struct SnapResult: Equatable, Sendable {
    public let snappedTime: CMTime
    public let isSnapped: Bool
    public let snappedTarget: CMTime?
    public let distancePixels: CGFloat
}

/// Snap engine managing cue boundary targets, zoom-aware tolerance, and dual-threshold hysteresis.
public final class PlayheadSnapper {
    public var pixelThreshold: CGFloat
    public var releaseThresholdFactor: CGFloat
    
    private var currentSnappedTarget: CMTime?
    
    public init(pixelThreshold: CGFloat = 8.0, releaseThresholdFactor: CGFloat = 1.75) {
        self.pixelThreshold = pixelThreshold
        self.releaseThresholdFactor = releaseThresholdFactor
    }
    
    public func reset() {
        currentSnappedTarget = nil
    }
    
    /// Computes the playhead position considering cue boundaries and hysteresis.
    public func snap(
        rawTime: CMTime,
        cues: [Cue],
        totalDuration: CMTime,
        pixelsPerSecond: Double,
        bypassSnapping: Bool = false
    ) -> SnapResult {
        if bypassSnapping || pixelThreshold <= 0 || pixelsPerSecond <= 0 {
            currentSnappedTarget = nil
            return SnapResult(snappedTime: rawTime, isSnapped: false, snappedTarget: nil, distancePixels: 0)
        }
        
        let rawPixels = CGFloat(rawTime.seconds * pixelsPerSecond)
        let releasePixels = pixelThreshold * releaseThresholdFactor
        
        // Check if currently snapped target remains within release threshold (hysteresis)
        if let snapped = currentSnappedTarget {
            let snappedPixels = CGFloat(snapped.seconds * pixelsPerSecond)
            let delta = abs(rawPixels - snappedPixels)
            if delta <= releasePixels {
                return SnapResult(
                    snappedTime: snapped,
                    isSnapped: true,
                    snappedTarget: snapped,
                    distancePixels: delta
                )
            } else {
                // Break away
                currentSnappedTarget = nil
            }
        }
        
        // Collect candidate snap targets: cue boundaries + 0 + duration
        var candidates: [CMTime] = [.zero, totalDuration]
        for cue in cues {
            candidates.append(cue.start)
            candidates.append(cue.end)
        }
        
        var closestTarget: CMTime?
        var minDelta: CGFloat = .greatestFiniteMagnitude
        
        for target in candidates {
            let targetPixels = CGFloat(target.seconds * pixelsPerSecond)
            let delta = abs(rawPixels - targetPixels)
            if delta < minDelta {
                minDelta = delta
                closestTarget = target
            }
        }
        
        if minDelta <= pixelThreshold, let target = closestTarget {
            currentSnappedTarget = target
            return SnapResult(
                snappedTime: target,
                isSnapped: true,
                snappedTarget: target,
                distancePixels: minDelta
            )
        }
        
        currentSnappedTarget = nil
        return SnapResult(
            snappedTime: rawTime,
            isSnapped: false,
            snappedTarget: nil,
            distancePixels: minDelta
        )
    }
}
```

---

## 5. Verification Method

### 5.1 Proposed Verification Test Suites
Create test suites under `Tests/AmendCoreTests/Suites/`:

1. **`TimelineClockTests.swift`**:
   - `test_continuous_clock_maintains_exact_subframe_precision()`:
     - Initialize `TimelineClock` with duration $60.0\text{s}$.
     - Scrub to $t = 1.234567\text{s}$ ($1{,}234{,}567\text{ microseconds}$).
     - Verify `clock.currentTime.seconds` equals $1.234567$ without rounding to video frames ($1/30\text{s}$).
   - `test_transport_state_machine_transitions()`:
     - Verify transitions: `.paused` $\to$ `.playing` $\to$ `.scrubbing` $\to$ `.paused`.
     - Verify `wasPlayingBeforeScrub` correctly restores `.playing` after scrub ends.
   - `test_loop_boundary_clamping()`:
     - Set `loopRange` to $[2.0\text{s}, 4.0\text{s}]$.
     - Simulate time tick at $4.01\text{s}$; assert clock wraps to $2.0\text{s}$.
2. **`SMPTERulerFormatterTests.swift`**:
   - `test_bidirectional_conversions_across_frame_rates()`:
     - Iterate through all 9 frame rates (`23.976`, `24`, `25`, `29.97 NDF`, `29.97 DF`, `30`, `59.94 NDF`, `59.94 DF`, `60`).
     - Convert sample timestamp $t = 125.5\text{s}$ to SMPTE and parse back; assert delta $< 1 / (2 \times \text{fps})$.
   - `test_drop_frame_edge_cases()`:
     - For 29.97 DF:
       - Assert frame before minute 1: `00:00:59;29` $\to$ next frame is `00:01:00;02` (frames `00` and `01` dropped).
       - Assert frame before minute 10: `00:09:59;29` $\to$ next frame is `00:10:00;00` (no frames dropped on decade minute).
   - `test_dynamic_ruler_tick_viewport_culling()`:
     - At $100\text{ px/s}$, viewport $[0, 500]$ px generates ticks only for $[0, 5]$ seconds; total tick count matches expected index count without generating ticks for unviewed minutes.
3. **`PlayheadSnapperTests.swift`**:
   - `test_pixel_to_time_threshold_scaling()`:
     - At $100\text{ px/s}$, $8\text{ px} = 0.08\text{ s}$. Raw time $1.05\text{ s}$ snaps to cue boundary $1.00\text{ s}$.
     - At $1000\text{ px/s}$, $8\text{ px} = 0.008\text{ s}$. Raw time $1.05\text{ s}$ does NOT snap to cue boundary $1.00\text{ s}$ ($50\text{ ms} > 8\text{ ms}$).
   - `test_dual_threshold_hysteresis()`:
     - Cursor enters $7\text{ px}$ from boundary $\to$ snaps.
     - Cursor moves to $11\text{ px}$ from boundary $\to$ stays snapped (within $14\text{ px}$ release threshold).
     - Cursor moves to $15\text{ px}$ from boundary $\to$ breaks away (unsnaps).
   - `test_modifier_bypass()`:
     - Passing `bypassSnapping: true` returns exact `rawTime` even when $1\text{ px}$ away.

### 5.2 Test Execution Command
To execute the test suite once implemented:
```bash
swift test --filter TimelineClockTests
swift test --filter SMPTERulerFormatterTests
swift test --filter PlayheadSnapperTests
```
And to verify zero regression across existing M1/M2 suites:
```bash
swift test --filter SyncInvariantTests
swift test --filter AudioRoutingTests
swift test --filter StorageAPFSTests
```

### 5.3 Invalidation Conditions
This architecture is invalidated if:
1. An implementation introduces `round(seconds * fps)` into `TimelineClock.currentTime` or `Cue.timeRange`.
2. AVPlayer seeking without debouncing causes UI main-thread drop below 60 Hz during playhead drag.
3. Drop-frame timecode math produces invalid frame numbers (e.g. `00:01:00;00` on 29.97 DF).
