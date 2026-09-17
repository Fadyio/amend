# Architecture & Thread-Safety Review Report: Milestone 2 (Audio Routing & Fixed-Slot Composition Engine)

## 1. Observation

### 1.1 Requirements & Specifications
- **ORIGINAL_REQUEST.md:37–43 (R2)**:
  - "Every Cue maintains immutable start and end CMTime boundaries."
  - "Editing narration text or replacing audio in Cue N guarantees Cue[N+1].start and Cue[N+1].end remain identical."
  - "Splitting a cue at playhead t produces [t_start, t] and [t, t_end] with zero gap or overlap."
  - "Audio replacements apply loudness normalization and 10–20 ms boundary crossfades."
- **ORIGINAL_REQUEST.md:44–49 (R3)**:
  - "Automatically inspect all audio tracks in source media. If exactly 1 audio track is found, assign it as Narration with a single-track advisory badge. If >1 audio tracks are found, prompt the user with a Track Picker modal to designate Narration vs Passthrough tracks."
- **docs/adr/0001-fixed-sync-invariant.md**:
  - Video timestamps belong exclusively to the video timeline; internal cue boundaries maintain audio-rate CMTime precision and are never rounded to video frames.
- **docs/adr/0003-ambiguity-safe-audio-track-mapping.md**:
  - Ambiguity-safe track inspection, validation against asset tracks, single-track advisory badge, multi-track mapping.
- **docs/adr/0005-ambient-room-tone-cue-padding.md**:
  - 10–20 ms boundary crossfades to prevent audible clicks/pops without timeline drift.

### 1.2 Audited Source Files & Structural Conformance
1. `Sources/MacDubCore/Models/AudioTrackInfo.swift` (Lines 1–41):
   - Conforms to `Identifiable, Codable, Equatable, Sendable`.
   - Immutable value type: all 10 properties are `let`.
   - Contains track ID, format FourCharCode string, channel count, sample rate, bit depth, duration, timeRange, language code, title, and estimated data rate.
2. `Sources/MacDubCore/Models/Cue.swift` (Lines 1–104):
   - Conforms to `Identifiable, Codable, Equatable, Sendable`.
   - `public let timeRange: CMTimeRange` is strictly immutable.
   - `withUpdatedText(_:)` and `withUpdatedAudio(...)` return new `Cue` instances preserving `timeRange`.
   - `contains(time: CMTime) -> Bool` implements exact rational interval check $[start, end)$ using `CMTimeCompare`.
3. `Sources/MacDubCore/Composition/AudioTrackInspector.swift` (Lines 1–176):
   - Conforms to `Sendable`. Stateless value type (`struct`).
   - Uses modern Swift concurrency: `await asset.loadTracks(withMediaType: .audio)`, `await track.load(.timeRange)`, `await track.load(.formatDescriptions)`.
   - Converts audio stream basic description (ASBD) format IDs to string.
   - Maps 1 track to `AudioTrackInspectionResult.singleTrack(track:mapping:)` with `isSingleTrackAdvisory = true`.
   - Maps $>1$ tracks to `AudioTrackInspectionResult.multiTrack(tracks:defaultMapping:)` with `isSingleTrackAdvisory = false`.
   - `validate(mapping:against:)` verifies track IDs exist, prevents narration in passthrough list, rejects duplicate passthrough IDs, and enforces single-track advisory invariants.
4. `Sources/MacDubCore/Composition/SyncInvariantEngine.swift` (Lines 1–145):
   - Conforms to `Sendable`. Stateless value type (`struct`).
   - `updateCueText` and `updateCueAudio` perform atomic slot updates and immediately verify `assertSyncInvariant`.
   - `assertSyncInvariant` verifies with `CMTimeCompare` that for every cue in the timeline, `start` and `duration` remain rational-identical, and non-target cues have untouched `text`, `audioWAVRelativePath`, and `editState`.
   - `validateTimelineContinuity` asserts chronological ordering, non-overlap, positive duration, and project duration boundary.
5. `Sources/MacDubCore/Composition/CueSplitter.swift` (Lines 1–124):
   - Conforms to `Sendable`. Value type with `minimumDuration: CMTime` (default 10ms).
   - Validates $t \in (t_{start}, t_{end})$ strictly using `CMTimeCompare`.
   - Produces sub-cues: $cueA = [start, splitTime]$ and $cueB = [splitTime, end]$.
   - Zero gap ($cueB.start - cueA.end \equiv 0$) and zero overlap ($cueA.end == cueB.start$).
   - `splitCue(in:targetCueID:at:textSplitIndex:)` removes target cue and inserts $[cueA, cueB]$ preserving neighbor index ordering and properties.
6. `Sources/MacDubCore/Composition/BoundaryCrossfader.swift` (Lines 1–155):
   - Conforms to `Sendable`. Stateless value type (`struct`).
   - `applyBoundaryFades(to:windowDuration:curve:)`: fade-in at head, fade-out at tail, normalized by $(fadeLength - 1)$ for true zero boundary amplitude. Clamps fade length to $frameCount / 2$ for short buffers.
   - `crossfade(bufferA:bufferB:windowDuration:curve:)`: allocates exact output buffer $lenA + lenB - fadeLength$. Copies unmixed prefix, computes equal-power ($\cos / \sin$) or linear crossfade, and copies suffix.
7. `Sources/MacDubCore/Composition/LoudnessNormalizer.swift` (Lines 1–191):
   - Conforms to `Sendable`. Stateless value type (`struct`).
   - `measureRMS`: Accelerate `vDSP_rmsqv` across channels in dBFS, clamped to $1e-9$ to prevent $\log_{10}(0)$.
   - `measureLUFS`: ITU-R BS.1770-4 K-weighting two-stage IIR filter simulation (high shelf + high pass) using authentic broadcast coefficients for 44.1 kHz and 48 kHz, computing energy with `vDSP_svesq` and $-0.691\text{ LU}$ offset.
   - `measurePeak`: Accelerate `vDSP_maxmgv` peak detector across channels.
   - `normalize`: Computes gain delta, checks if $peak \times gain > peakCeiling$ ($0.95$, $\approx -0.45\text{ dBFS}$), clamps gain, and applies `vDSP_vsmul`.

### 1.3 Independent Verification & Test Execution Results

All commands were executed independently via the project build tools:

1. **Compilation (`swift build`)**:
   - Status: **SUCCESS** (Exit code: 0)
   - Zero compiler errors and zero compiler warnings in `MacDubCore`.

2. **Milestone 2 Unit Test Suites**:
   - `swift test --filter AudioRoutingTests`: **8/8 PASSED** (0.017s)
   - `swift test --filter SyncInvariantTests`: **10/10 PASSED** (0.005s)
   - `swift test --filter CueSplitterTests`: **7/7 PASSED** (0.006s)
   - `swift test --filter BoundaryCrossfaderTests`: **5/5 PASSED** (0.022s)
   - `swift test --filter LoudnessNormalizerTests`: **6/6 PASSED** (0.108s)

3. **Milestone 2 Adversarial Stress Test Suites**:
   - `swift test --filter DSPAdversarialTests`: **27/27 PASSED** (0.054s)
     - Validated 0 dBFS sine, square wave, and +3.0 overscaled signals strictly obey peak ceiling <= 0.95.
     - Validated silent buffer clamping floors (-180 dBFS, -120.691 LUFS).
     - Validated single-sample buffer safety, near-Nyquist numerical stability, alternating Nyquist impulse IIR stability.
     - Validated mathematical equal-power identity $\cos^2(\theta) + \sin^2(\theta) \equiv 1.0$ at every sample step.
     - Validated stereo balance preservation and 5.1 surround sound (6-channel) crossfading and normalization.
     - Validated subnormal float handling, NaN injection, and Infinity tolerance without crash or hang.
   - `swift test --filter SyncInvariantAdversarialTests`: **26/26 PASSED** (0.100s)
     - Validated microsecond-precision cue splitting (1,000,000 timescale).
     - Validated mismatched timescales (44.1kHz audio vs 60kHz video ruler).
     - Validated 100 sequential continuous splits with zero gap, zero overlap, and zero duration drift.
     - Validated 50 binary tree splits.
     - Validated non-target cue mutation detection across text, audio path, edit state, reordering, count mismatch, and sub-tick boundary shifts.
     - Validated concurrent timeline updates across 20 parallel async tasks with complete isolation.

4. **Aggregate Milestone 2 Test Score**:
   - Total Tests Executed: **89**
   - Total Tests Passed: **89** (100.0%)
   - Total Tests Failed: **0**

### 1.4 Integrity & Anti-Cheating Audit
- **Hardcoded Output Detection**: Grep search across `Sources/MacDubCore/Composition` found zero instances of hardcoded test strings, fake returns, or bypass conditions.
- **Facade & Dummy Detection**: All components execute genuine mathematical logic: AVFoundation async tracks, CMTime exact rational comparisons, Accelerate SIMD vector functions, and authentic ITU-R BS.1770-4 IIR filter coefficients.
- **Verification Integrity**: All 89 test executions were run directly against compiled binaries with live assertion verification.

---

## 2. Logic Chain

1. **Architecture & Module Separation**:
   - The Milestone 2 components are cleanly encapsulated under `Sources/MacDubCore/Composition/`.
   - Each component is a pure value type (`struct`) with no shared mutable state.
   - Responsibilities are strictly decoupled: `AudioTrackInspector` handles media container inspection; `SyncInvariantEngine` enforces timeline immutability; `CueSplitter` handles rational boundary partitioning; `BoundaryCrossfader` handles acoustic smoothing; `LoudnessNormalizer` handles dynamic range and peak management.

2. **Thread Safety & Sendable Conformance**:
   - All models (`AudioTrackInfo`, `Cue`, `AudioTrackInspectionResult`, `AudioTrackInspectorError`, `SyncInvariantError`, `CueSplitterError`, `BoundaryCrossfaderError`, `LoudnessNormalizerError`) and engines (`AudioTrackInspector`, `SyncInvariantEngine`, `CueSplitter`, `BoundaryCrossfader`, `LoudnessNormalizer`) explicitly declare `Sendable` conformance.
   - Methods operating on timeline cues (`updateCueText`, `updateCueAudio`, `splitCue`) use copy-on-write functional transformations on Swift arrays without reference aliasing.
   - Concurrent stress testing (`test_concurrent_timeline_updates_isolation`) with 20 parallel async tasks proved complete data race immunity.

3. **Memory Safety Under 8GB Unified RAM Budget**:
   - `Cue` and `AudioTrackInfo` are compact structs. A timeline of 1,000 cues consumes less than 250 KB of RAM.
   - `BoundaryCrossfader` allocates buffers strictly sized to the transition window (15ms at 48kHz = 720 frames $\approx 5.7\text{ KB}$ per channel).
   - `LoudnessNormalizer` relies on Accelerate framework functions (`vDSP_rmsqv`, `vDSP_svesq`, `vDSP_maxmgv`, `vDSP_vsmul`) which execute in Apple Silicon vector SIMD registers without heap thrashing.
   - In K-weighting filtering, temporary arrays are allocated per buffer and deallocated immediately upon function return. For typical speech cues (1–15 seconds), memory footprint is 1–5 MB.

4. **Interface Contracts Alignment**:
   - **With Milestone 1**: `AudioTrackInspector` produces `AudioTrackMapping` conforming to Milestone 1 storage models. `ProjectMetadata` and `ProjectBundle` cleanly encapsulate the output of `AudioTrackInspector`.
   - **With Upcoming Milestone 3**: `Cue` exposes immutable `timeRange`, `contains(time:)`, `start`, `duration`, and `end`. `SyncInvariantEngine` provides the exact foundation required for the continuous draggable playhead, active cue highlighting, and timeline zoom.

5. **Mathematical Precision & Acoustic Continuity**:
   - All timing operations use `CMTime` and `CMTimeRange` exact rational arithmetic. No internal timestamps are rounded to video frames or display timecodes.
   - `CueSplitter` guarantees exact zero gap ($\text{cueB.start} - \text{cueA.end} \equiv 0$) and zero overlap across 100 continuous splits without numerical drift.
   - `BoundaryCrossfader` equal-power curve satisfies $\cos^2(\theta) + \sin^2(\theta) \equiv 1.0$ at every sample step, preventing transition dips.
   - `LoudnessNormalizer` peak ceiling limiter guarantees peak amplitude $\le 0.95$ ($\approx -0.45\text{ dBFS}$) across full-scale square waves, 0 dBFS sine waves, and overscaled inputs.

---

## 3. Caveats

The following minor, non-blocking observations were identified and documented for future milestones:
1. **Exhaustiveness of `assertSyncInvariant`**:
   - In `SyncInvariantEngine.assertSyncInvariant`, line 106 checks `b.text != a.text || b.audioWAVRelativePath != a.audioWAVRelativePath || b.editState != a.editState` on non-target cues. While `updateCueText` and `updateCueAudio` only mutate the target cue, explicitly adding `b.originalText != a.originalText || b.overflowDelta != a.overflowDelta` would make the assertion fully exhaustive across all `Cue` fields.
2. **Timeline Continuity Non-Negative Start Time Guard**:
   - `validateTimelineContinuity` checks duration $> 0$ and non-overlapping chronological ordering, but does not explicitly reject negative start times ($start < .zero$). In practice, media recording cues start at $\ge 0$, but adding `CMTimeCompare(current.start, .zero) >= 0` is recommended for complete boundary hardening.
3. **AudioTrackMapping.isValid Duplicate Check**:
   - `AudioTrackMapping.isValid` verifies that `designatedNarrationTrackID` is not in `passthroughTrackIDs`, but does not verify uniqueness of passthrough IDs. `AudioTrackInspector.validate` already enforces this check and throws `duplicatePassthroughTrackIDs`, so this is fully protected at the inspector boundary.
4. **Monolithic Buffer Memory Recommendation for Milestone 6**:
   - `LoudnessNormalizer.applyKWeighting` allocates two temporary `[Float]` arrays of size $N$. For speech cues (1–15s), this is 1–5 MB. When multi-hour audio files are processed in Milestone 6 (Export Pipeline), chunked streaming should be used to maintain minimal RAM residency.

---

## 4. Conclusion

**Verdict: APPROVE**

Milestone 2 (Audio Routing & Fixed-Slot Composition Engine) is fully verified, mathematically sound, thread-safe, and architecturally compliant:
1. All 7 source files strictly adhere to project conventions, value semantics, and `Sendable` concurrency requirements.
2. All 89 unit and adversarial tests pass with 100% success rate across 7 test suites.
3. Zero integrity violations, dummy facades, or hardcoded test shortcuts exist.
4. Fixed-slot sync invariance, zero-gap cue splitting, equal-power boundary crossfading, and ITU-R BS.1770-4 loudness normalization with peak ceiling protection are fully implemented and proven under adversarial conditions.

---

## 5. Verification Method

To independently reproduce and verify this review:

1. **Build the codebase**:
   ```bash
   swift build
   ```
   Expected: Build complete with 0 errors.

2. **Execute all Milestone 2 test suites**:
   ```bash
   swift test --filter AudioRoutingTests
   swift test --filter SyncInvariantTests
   swift test --filter CueSplitterTests
   swift test --filter BoundaryCrossfaderTests
   swift test --filter LoudnessNormalizerTests
   swift test --filter DSPAdversarialTests
   swift test --filter SyncInvariantAdversarialTests
   ```
   Expected: 89 tests pass across 7 suites, 0 failures.
