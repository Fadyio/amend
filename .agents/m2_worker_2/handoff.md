# Handoff Report: Milestone 2 — Audio Routing & Fixed-Slot Composition Engine

## 1. Observation

### 1.1 Requirements & ADR Specifications
- **ORIGINAL_REQUEST.md:37–43 (R2)**:
  - "Every Cue maintains immutable start and end CMTime boundaries."
  - "Editing narration text or replacing audio in Cue N guarantees Cue[N+1].start and Cue[N+1].end remain identical."
  - "Splitting a cue at playhead t produces [t_start, t] and [t, t_end] with zero gap or overlap."
  - "Audio replacements apply loudness normalization and 10–20 ms boundary crossfades."
- **ORIGINAL_REQUEST.md:44–49 (R3)**:
  - "Automatically inspect all audio tracks in source media. If exactly 1 audio track is found, assign it as Narration with a single-track advisory badge. If >1 audio tracks are found, prompt the user with a Track Picker modal to designate Narration vs Passthrough tracks."
- **docs/adr/0001-fixed-sync-invariant.md:3**:
  - "We decided that video timestamps are strictly immutable (`CMTime` / `CMTimeRange`), meaning cues never shift when narration is edited."
- **docs/adr/0003-ambiguity-safe-audio-track-mapping.md:3**:
  - "...inspect all audio tracks on import: if exactly one audio track exists, it is automatically assigned as Narration with a single-track warning; if multiple tracks exist, a lightweight Track Picker modal prompts the user to confirm the Narration track and Passthrough tracks."
- **docs/adr/0005-ambient-room-tone-cue-padding.md:3**:
  - "10–20 ms boundary crossfades are applied to guarantee seamless acoustic continuity and exact `CMTimeRange` adherence."

### 1.2 Implemented Source Files & Line Numbers
1. `Sources/MacDubCore/Models/AudioTrackInfo.swift` (Lines 1–36):
   - Model representing inspected audio track details (`id: Int`, `format: String`, `channelCount: Int`, `sampleRate: Double`, `bitDepth: Int?`, `duration: CMTime`, `timeRange: CMTimeRange`, `languageCode: String?`, `title: String?`, `estimatedDataRate: Float`). Conforms to `Identifiable`, `Codable`, `Equatable`, `Sendable`.
2. `Sources/MacDubCore/Models/Cue.swift` (Lines 68–104):
   - Extensions `withUpdatedText(_ newText: String) -> Cue`: generates updated cue preserving immutable `timeRange` and `originalText`.
   - `withUpdatedAudio(audioWAVRelativePath: String?, editState: CueEditState, overflowDelta: CMTime? = nil) -> Cue`: preserves immutable `timeRange`.
   - `contains(time: CMTime) -> Bool`: exact rational interval containment check `CMTimeCompare(time, start) >= 0 && CMTimeCompare(time, end) < 0`.
3. `Sources/MacDubCore/Composition/AudioTrackInspector.swift` (Lines 1–178):
   - `AudioTrackInspectionResult` enum (`.singleTrack`, `.multiTrack`, `.noAudioTracks`).
   - `AudioTrackInspectorError` localized errors (`fileNotFound`, `unreadableAsset`, `noAudioTracksFound`, `designatedTrackNotInAsset`, `passthroughTrackNotInAsset`, `narrationInPassthroughList`, `duplicatePassthroughTrackIDs`, `singleTrackAdvisoryViolation`).
   - `inspect(assetURL: URL) async throws -> AudioTrackInspectionResult` and `inspect(asset: AVAsset) async throws -> AudioTrackInspectionResult`.
   - `validate(mapping: AudioTrackMapping, against tracks: [AudioTrackInfo]) throws`.
4. `Sources/MacDubCore/Composition/SyncInvariantEngine.swift` (Lines 1–142):
   - `SyncInvariantError` enum (`cueNotFound`, `overlappingCues`, `cuesOutOfChronologicalOrder`, `zeroOrNegativeDuration`, `timeExceedsProjectDuration`, `invariantViolationBoundaryShifted`, `nonTargetCueMutated`).
   - `updateCueText(in:cueID:newText:) throws -> [Cue]`.
   - `updateCueAudio(in:cueID:audioRelativePath:editState:overflowDelta:) throws -> [Cue]`.
   - `assertSyncInvariant(before:after:modifiedCueID:) throws`: exact rational equality checks across non-target and target cues.
   - `validateTimelineContinuity(cues:totalDuration:) throws`.
5. `Sources/MacDubCore/Composition/CueSplitter.swift` (Lines 1–123):
   - `CueSplitterError` enum (`targetCueNotFound`, `splitTimestampOutOfBounds`, `resultingDurationTooShort`).
   - `split(cue:at:textSplitIndex:) throws -> (cueA: Cue, cueB: Cue)`.
   - `splitCue(in:targetCueID:at:textSplitIndex:) throws -> (updatedCues: [Cue], splitA: Cue, splitB: Cue)`.
   - Guarantees 0 gap (`cueB.start - cueA.end == 0`), 0 overlap (`cueA.end == cueB.start`), and neighbor immutability.
6. `Sources/MacDubCore/Composition/BoundaryCrossfader.swift` (Lines 1–143):
   - `CrossfadeCurve` enum (`linear`, `equalPower`).
   - `BoundaryCrossfaderError` enum (`invalidBuffer`, `unsupportedAudioFormat`).
   - `applyBoundaryFades(to:windowDuration:curve:) throws`: fade-in at head, fade-out at tail, normalized by `(fadeLength - 1)` for true zero boundary amplitude.
   - `crossfade(bufferA:bufferB:windowDuration:curve:) throws -> AVAudioPCMBuffer`: equal-power $\cos(\theta) + \sin(\theta)$ and linear crossfading preserving acoustic energy.
7. `Sources/MacDubCore/Composition/LoudnessNormalizer.swift` (Lines 1–168):
   - `LoudnessNormalizerError` enum (`unsupportedAudioFormat`, `emptyBuffer`, `zeroSampleRate`).
   - `measureRMS(buffer: AVAudioPCMBuffer) throws -> Double`: Accelerate `vDSP_rmsqv` calculation in dBFS.
   - `measureLUFS(buffer: AVAudioPCMBuffer) throws -> Double`: ITU-R BS.1770-4 K-weighting two-stage IIR filter simulation.
   - `measurePeak(buffer: AVAudioPCMBuffer) throws -> Float`: Accelerate `vDSP_maxmgv` peak detector.
   - `normalize(buffer:targetLUFS:peakCeiling:) throws -> (normalizedBuffer: AVAudioPCMBuffer, appliedGainDB: Double)`.
   - `matchLoudness(sourceBuffer:referenceBuffer:peakCeiling:) throws -> (normalizedBuffer: AVAudioPCMBuffer, appliedGainDB: Double)`.

### 1.3 Test Suites & Execution Output
Executed unit tests with Swift Testing (`swift test --filter ...`):
1. `AudioRoutingTests.swift` (Lines 1–183):
   - Command: `swift test --filter AudioRoutingTests`
   - Output:
     ```text
     􀟈 Suite "Audio Routing Tests" started.
     􁁛 Test "Validation rejects non-existent track ID" passed after 0.001 seconds.
     􁁛 Test "Validation rejects duplicate passthrough track IDs" passed after 0.001 seconds.
     􁁛 Test "Validation rejects narration track also present in passthrough" passed after 0.001 seconds.
     􁁛 Test "Single-track audio mapping returns singleTrack advisory mapping" passed after 0.001 seconds.
     􁁛 Test "Multi-track mapping assigns narration and passthrough tracks" passed after 0.001 seconds.
     􁁛 Test "Validation rejects single-track advisory on multi-track asset" passed after 0.002 seconds.
     􁁛 Test "Validation rejects non-existent passthrough track ID" passed after 0.002 seconds.
     􁁛 Test "Inspector inspects non-existent file and throws fileNotFound" passed after 0.018 seconds.
     􁁛 Suite "Audio Routing Tests" passed after 0.018 seconds.
     􁁛 Test run with 8 tests in 1 suite passed after 0.018 seconds.
     ```
2. `SyncInvariantTests.swift` (Lines 1–197):
   - Command: `swift test --filter SyncInvariantTests`
   - Output:
     ```text
     􀟈 Suite "Sync Invariant Tests" started.
     􁁛 Test "Timeline continuity validates chronological non-overlapping cues" passed after 0.002 seconds.
     􁁛 Test "Modifying text of Cue N leaves Cue N+1 boundaries strictly immutable" passed after 0.002 seconds.
     􁁛 Test "Cue contains(time:) checks boundary containment accurately" passed after 0.002 seconds.
     􁁛 Test "Replacing audio of Cue N preserves immutable slot timeRange" passed after 0.002 seconds.
     􁁛 Test "Sync invariant rejects non-target cue mutations" passed after 0.004 seconds.
     􁁛 Test "Timeline continuity rejects out-of-order cues" passed after 0.004 seconds.
     􁁛 Test "Timeline continuity rejects zero or negative duration cue" passed after 0.009 seconds.
     􁁛 Test "Timeline continuity rejects cues exceeding total project duration" passed after 0.009 seconds.
     􁁛 Test "Timeline continuity rejects overlapping cues" passed after 0.009 seconds.
     􁁛 Test "Sync invariant rejects boundary shifts in target cue" passed after 0.009 seconds.
     􁁛 Suite "Sync Invariant Tests" passed after 0.009 seconds.
     􁁛 Test run with 10 tests in 1 suite passed after 0.010 seconds.
     ```
3. `CueSplitterTests.swift` (Lines 1–142):
   - Command: `swift test --filter CueSplitterTests`
   - Output:
     ```text
     􀟈 Suite "Cue Splitter Tests" started.
     􁁛 Test "Cue split with explicit text split index" passed after 0.001 seconds.
     􁁛 Test "Cue split rejects non-existent cue ID in timeline" passed after 0.002 seconds.
     􁁛 Test "Cue split produces exact zero gap and zero overlap" passed after 0.002 seconds.
     􁁛 Test "Cue split rejects duration below minimum threshold" passed after 0.009 seconds.
     􁁛 Test "Cue split rejects splitTime before start" passed after 0.009 seconds.
     􁁛 Test "Cue split rejects splitTime after end" passed after 0.009 seconds.
     􁁛 Test "Cue split rejects splitTime exactly at boundary" passed after 0.010 seconds.
     􁁛 Suite "Cue Splitter Tests" passed after 0.010 seconds.
     􁁛 Test run with 7 tests in 1 suite passed after 0.010 seconds.
     ```
4. `BoundaryCrossfaderTests.swift` (Lines 1–124):
   - Command: `swift test --filter BoundaryCrossfaderTests`
   - Output:
     ```text
     􀟈 Suite "Boundary Crossfader Tests" started.
     􁁛 Test "Crossfade rejects mismatched sample rates or channels" passed after 0.004 seconds.
     􁁛 Test "Boundary crossfader handles short buffers safely" passed after 0.004 seconds.
     􁁛 Test "Boundary crossfader equal-power fade-in and fade-out" passed after 0.011 seconds.
     􁁛 Test "Crossfade two buffers preserves equal-power sum across overlap region" passed after 0.013 seconds.
     􁁛 Test "Boundary crossfader linear fade-in and fade-out" passed after 0.013 seconds.
     􁁛 Suite "Boundary Crossfader Tests" passed after 0.013 seconds.
     􁁛 Test run with 5 tests in 1 suite passed after 0.013 seconds.
     ```
5. `LoudnessNormalizerTests.swift` (Lines 1–105):
   - Command: `swift test --filter LoudnessNormalizerTests`
   - Output:
     ```text
     􀟈 Suite "Loudness Normalizer Tests" started.
     􁁛 Test "Empty buffer throws error on measurement" passed after 0.005 seconds.
     􁁛 Test "RMS measurement calculates accurate dBFS for sine wave" passed after 0.013 seconds.
     􁁛 Test "Peak measurement detects maximum absolute amplitude" passed after 0.024 seconds.
     􁁛 Test "Normalization adjusts gain and strictly respects peak ceiling" passed after 0.066 seconds.
     􁁛 Test "LUFS measurement calculates BS.1770-4 K-weighted loudness" passed after 0.069 seconds.
     􁁛 Test "Match loudness adjusts source buffer to reference buffer loudness" passed after 0.120 seconds.
     􁁛 Suite "Loudness Normalizer Tests" passed after 0.120 seconds.
     􁁛 Test run with 6 tests in 1 suite passed after 0.120 seconds.
     ```
6. Existing Baseline Regressions:
   - `StorageAPFSTests`: 7/7 passed in 0.017 seconds.
   - `SecuritySuiteTests`: 10/10 passed in 0.158 seconds.

---

## 2. Logic Chain

1. **Audio Track Routing & Advisory Integrity**:
   - `AudioTrackInspector` inspects container audio tracks via AVFoundation async track loading (`asset.loadTracks(withMediaType: .audio)`), extracting `CMPersistentTrackID`, audio format FourCharCode (e.g. `lpcm`, `aac `), channel count, sample rate, and bit depth.
   - When exactly 1 track exists, `AudioTrackInspectionResult.singleTrack(track:mapping:)` creates `AudioTrackMapping.singleTrack(trackID:)` with `isSingleTrackAdvisory = true`.
   - When $>1$ tracks exist, `AudioTrackInspectionResult.multiTrack(tracks:defaultMapping:)` sets `designatedNarrationTrackID = tracks[0].id`, `passthroughTrackIDs = tracks[1...].id`, and `isSingleTrackAdvisory = false`.
   - `AudioTrackInspector.validate` validates track existence, non-overlap between narration and passthrough, absence of duplicate passthrough IDs, and adherence to single-track constraints.
2. **Fixed-Slot Sync Invariance**:
   - Per ADR 0001, video timestamps belong exclusively to the video timeline.
   - In `SyncInvariantEngine.updateCueText` and `updateCueAudio`, the edited cue retains its exact `timeRange: CMTimeRange`.
   - `assertSyncInvariant` verifies with `CMTimeCompare` that for every cue in the timeline, `start` and `duration` remain rational-identical.
   - For all $k \ne N$, `text`, `audioWAVRelativePath`, and `editState` remain bitwise identical, confirming no ripple drift.
3. **Continuous Zero-Gap Splitting**:
   - For any cue with interval $[t_{start}, t_{end})$ and valid $t \in (t_{start}, t_{end})$, `CueSplitter.split` computes:
     $\text{duration}_A = \text{CMTimeSubtract}(t, t_{start})$
     $\text{duration}_B = \text{CMTimeSubtract}(t_{end}, t)$
   - Gap: $\text{CMTimeSubtract}(\text{cueB.start}, \text{cueA.end}) \equiv \text{CMTimeSubtract}(t, t) = 0$.
   - Overlap: $\text{CMTimeSubtract}(\text{cueA.end}, \text{cueB.start}) \equiv 0$.
   - Neighbors: In `splitCue(in:targetCueID:at:textSplitIndex:)`, the target cue at index $N$ is replaced by $[C_A, C_B]$. All cues $i < N$ and $i > N$ are preserved without modification.
4. **Boundary Crossfader Anti-Discontinuity**:
   - Splicing audio buffers at non-zero crossings produces audible clicks.
   - `BoundaryCrossfader` normalizes the fade curve index $i$ by $(N - 1)$, ensuring the first sample is $0.0$ on fade-in and the last sample is $0.0$ on fade-out.
   - For equal power, $w_A(i) = \cos(\frac{\pi}{2} \cdot \frac{i}{N-1})$ and $w_B(i) = \sin(\frac{\pi}{2} \cdot \frac{i}{N-1})$, satisfying $w_A(i)^2 + w_B(i)^2 \equiv 1.0$, preventing mid-transition power dips.
5. **Acoustic Loudness Normalization**:
   - `LoudnessNormalizer` implements ITU-R BS.1770-4 K-weighting two-stage IIR filtering (pre-filter high shelf + RLB high pass) and computes energy-weighted loudness with the $-0.691$ LU offset.
   - Peak ceiling limiter prevents digital clipping by clamping linear gain when $\text{peak} \times \text{gain} > \text{peakCeiling}$ ($0.95$, $\sim -0.45\text{ dBFS}$).

---

## 3. Caveats

1. **Float32 PCM Requirement**:
   - `BoundaryCrossfader` and `LoudnessNormalizer` operate on 32-bit float non-interleaved `AVAudioPCMBuffer` instances (the standard audio format in macOS AVFoundation and CoreAudio pipelines). If raw 16-bit integer PCM buffers are read from older containers, they must be converted using `AVAudioConverter` prior to processing.
2. **Audio Track Inspector on Encrypted / DRM Media**:
   - If media files have protected DRM tracks or missing permissions, `AVAsset.loadTracks` will throw, and `AudioTrackInspector` wraps the error in `AudioTrackInspectorError.unreadableAsset`.

---

## 4. Conclusion

Milestone 2 (Audio Routing & Fixed-Slot Composition Engine) is fully implemented, verified, and complete:
1. `AudioTrackInfo` and `AudioTrackInspector` provide ambiguity-safe track classification, advisory badges, and routing validation.
2. `Cue` extensions provide immutable functional updates and continuous time containment checks.
3. `SyncInvariantEngine` guarantees that video timestamps never move and all neighbor cues remain bit-level invariant across edits.
4. `CueSplitter` guarantees exact 0 gap and 0 overlap continuous cue splitting with neighbor immutability.
5. `BoundaryCrossfader` applies 10–20ms linear and equal-power windowing to eliminate clicks.
6. `LoudnessNormalizer` provides ITU-R BS.1770-4 K-weighting LUFS and RMS measurement with peak ceiling protection.
7. 100% of all 36 Milestone 2 unit tests pass cleanly.

---

## 5. Verification Method

### 5.1 Compilation
```bash
swift build
```
Verify zero compiler errors and zero warnings in MacDubCore.

### 5.2 Unit Test Execution
Execute all five Milestone 2 suites individually:
```bash
swift test --filter AudioRoutingTests
swift test --filter SyncInvariantTests
swift test --filter CueSplitterTests
swift test --filter BoundaryCrossfaderTests
swift test --filter LoudnessNormalizerTests
```
Expected output: 36 tests pass across 5 suites, 0 failures.

### 5.3 Baseline Regression Check
```bash
swift test --filter StorageAPFSTests
swift test --filter SecuritySuiteTests
```
Expected output: 17 tests pass across 2 suites, 0 failures.
