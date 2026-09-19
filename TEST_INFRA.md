# Amend Test Infrastructure (`TEST_INFRA.md`)

## 1. Architectural Overview & Test Philosophy

Amend is a professional macOS application for screen recording speech editing, narration replacement, and voice cloning that strictly enforces an **immutable video timeline with zero synchronization drift**.

To guarantee synchronization integrity across multi-agent development cycles without human judgment, Amend employs a **Dual-Track E2E Testing Architecture**:
- **Implementation Track**: Progressively builds modules (M1 through M6) following architectural decision records (ADRs).
- **E2E Testing Track**: Independently designs, maintains, and executes an opaque-box, requirement-driven test harness using programmatically generated **Synthetic AVFoundation Fixtures**.

### Key Principles
1. **Deterministic AV Synthesis & Minimal Speech Provenance**: Deterministic AV/video test fixtures remain programmatically synthesized in milliseconds using native `AVFoundation`, `CoreMedia`, and `CoreVideo` APIs. A small, explicitly licensed human-speech WAV fixture (`human_speech_reference.wav`, ~247 KB, CC0 public domain) is committed under `Tests/AmendCoreTests/Fixtures/` solely for opt-in ASR and PocketTTS neural acceptance testing. Ordinary CI remains entirely deterministic without downloading neural models or storing large recorded videos in git.
2. **Opaque-Box Requirement Verification**: Tests exercise public subsystem boundaries and observable behaviors rather than internal implementation details.
3. **Rigorous Invariant Enforcement**: Every cue edit, split, duration fit, and export is validated against mathematical `CMTime` invariants.
4. **Sample Payload Identity**: The passthrough export pipeline is verified by asserting bit-for-bit SHA-256 payload identity between source and exported compressed video sample buffers (`CMSampleBuffer`).

---

## 2. The 4-Tier Test Hierarchy

Testing is organized into four distinct tiers covering depth, boundaries, integration seams, and realistic workflows:

```
┌─────────────────────────────────────────────────────────┐
│       Tier 4: Real-World Application Workflows          │ (End-to-End User Journeys)
├─────────────────────────────────────────────────────────┤
│       Tier 3: Cross-Feature Combinations                │ (Pairwise Integration Seams)
├─────────────────────────────────────────────────────────┤
│       Tier 2: Boundary & Corner Cases                   │ (Extreme Durations, Zero Gaps, Concurrency)
├─────────────────────────────────────────────────────────┤
│       Tier 1: Feature Coverage (>=5 tests per feature)  │ (Core Contracts, Positive Paths)
└─────────────────────────────────────────────────────────┘
```

### Tier 1: Feature Coverage (>=5 tests per feature)
- Validates primary contracts for each feature defined in `PROJECT.md` and `ORIGINAL_REQUEST.md`.
- Verifies positive paths: Single-track import, multi-track audio inspection, APFS copy-on-write cloning, bookmark fallback creation, project bundle serialization, fixed-slot boundary preservation, waveform extraction, room-tone sampling, and non-decoding passthrough export.

### Tier 2: Boundary & Corner Cases (>=5 tests per feature)
- Stresses boundary conditions and edge cases:
  - Microsecond and sub-millisecond `CMTime` rational precision.
  - Zero-duration and 1-sample cue splits.
  - Duration overflow thresholds: exactly $0.0\%$, $+4.0\%$, $+8.0\%$, $+8.01\%$, and $+15.0\%$.
  - Extreme payloads: 64 KB credentials in Keychain, deep directory hierarchies, non-ASCII filenames, whitespace-only transcripts.
  - Asynchronous task cancellation and concurrency safety.

### Tier 3: Cross-Feature Combinations (Pairwise Interaction Suites)
- Verifies integration seams between independent subsystems using pairwise matrix combinations:
  - *Storage × Timeline*: APFS cloned project loaded into `CMTime` timeline engine.
  - *Audio Inspection × Composition*: Multi-track media routed through fixed-slot composition.
  - *Cue Splitting × Duration Fitting*: Split cue followed by room-tone padding on segment A and pitch compression on segment B.
  - *Synthesis × Passthrough Export*: Rebuilt narration audio multiplexed alongside untouched video bitstream and untouched passthrough audio tracks.

### Tier 4: Real-World Application Scenarios (End-to-End Workflows)
- End-to-end user workflows executed from import to exported media:
  - **Scenario A (Single-Track Screencast)**: Import single-track recording -> advisory badge verified -> auto-transcribe cues -> split cue at playhead -> edit transcript -> re-render audio with room-tone padding -> export container -> verify total duration matches source to the exact sample.
  - **Scenario B (Multi-Track Tutorial)**: Import media with mic + system audio -> interactive track picker designates narration vs passthrough -> APFS clone to `.amend` bundle -> replace narration cue with cloned voice -> export -> verify passthrough system audio bitstream is intact and unaltered.
  - **Scenario C (Manual Overflow Gated Journey)**: Import recording -> synthesize replacement audio with $+15\%$ duration overflow -> assert system enters gated state -> execute "Rewrite to Fit" -> verify replacement fits within slot duration -> export and verify video sync.

---

## 3. Synthetic AVFoundation Fixture Architecture

All programmatic fixtures are located under `Tests/AmendCoreTests/Fixtures/` and generate programmatically valid, playable QuickTime (`.mov`) and MPEG-4 (`.mp4`) assets on demand. In addition, an authentic CC0-licensed human-speech reference fixture (`human_speech_reference.wav`) is included exclusively for opt-in local neural acceptance tests (`AMEND_RUN_LOCAL_AI_TESTS=1`).

### Architecture Diagram
```
┌─────────────────────────────────────────────────────────────────┐
│                  SyntheticFixtureGenerator                      │
│  - AVAssetWriter + AVAssetWriterInputPixelBufferAdaptor         │
│  - Linear PCM Audio Input (AVFormatIDKey: kAudioFormatLinearPCM)│
│  - Hardware-Accelerated H.264 Video Frames (CVPixelBuffer)      │
└────────────────┬───────────────────────┬────────────────────────┘
                 │                       │
      ┌──────────▼──────────┐ ┌──────────▼──────────┐ ┌───────────▼───────────┐
      │ Fixture1SingleTrack │ │ Fixture2MultiTrack  │ │Fixture3DurationFitting│
      │ - 1 Video Track     │ │ - 1 Video Track     │ │ - Base Media & Slots  │
      │ - 1 Narration Track │ │ - Track 1: Narration│ │ - -25% Padded Buffer  │
      │ - Known Cues/Gaps   │ │ - Track 2: Passthru │ │ - +4% Compressed Buf  │
      │                     │ │                     │ │ - +8% Boundary Buf    │
      │                     │ │                     │ │ - +15% Overflow Buf   │
      └─────────────────────┘ └─────────────────────┘ └───────────────────────┘
```

### Fixture Specifications

#### Fixture 1: Single-Track Media (`Fixture1SingleTrack.swift`)
- **Container**: QuickTime Movie (`.mov`)
- **Video Track**: 640×360 @ 30 fps, H.264, 10.0 seconds duration (300 frames).
- **Audio Track**: 1 track, 44.1 kHz, 16-bit Mono Linear PCM.
- **Audio Structure**:
  - `[0.0s, 1.0s]`: Silence (Ambient Room Tone region for sampling)
  - `[1.0s, 3.5s]`: 440 Hz Sine Tone (Speech Cue 1: 2.5s duration)
  - `[3.5s, 4.5s]`: Silence (Inter-cue gap: 1.0s duration)
  - `[4.5s, 7.5s]`: 880 Hz Sine Tone (Speech Cue 2: 3.0s duration)
  - `[7.5s, 8.5s]`: Silence (Inter-cue gap: 1.0s duration)
  - `[8.5s, 9.5s]`: 440 Hz Sine Tone (Speech Cue 3: 1.0s duration)
  - `[9.5s, 10.0s]`: Silence (Tail silence: 0.5s duration)
- **Ground Truth Cues**:
  - Cue 1: `start: 1.0s`, `duration: 2.5s`, text: "Welcome to Amend screen recording"
  - Cue 2: `start: 4.5s`, `duration: 3.0s`, text: "This is the second narration segment"
  - Cue 3: `start: 8.5s`, `duration: 1.0s`, text: "Conclusion"
- **Primary Use**: Waveform extraction tests, single-track advisory badge, cue splitting, and export duration preservation.

#### Fixture 2: Multi-Track Media (`Fixture2MultiTrack.swift`)
- **Container**: QuickTime Movie (`.mov`)
- **Video Track**: 640×360 @ 30 fps, H.264, 10.0 seconds duration.
- **Audio Track 1 (Narration)**: 44.1 kHz Mono Linear PCM matching Fixture 1 pattern (tone bursts + silence).
- **Audio Track 2 (Passthrough / Background)**: 44.1 kHz Mono Linear PCM containing continuous 220 Hz low-amplitude background audio without silence.
- **Primary Use**: Multi-track detection, Track Picker modal logic, track routing, and verifying that Track 2 samples pass through untouched during export.

#### Fixture 3: Duration Fitting Media (`Fixture3DurationFitting.swift`)
- **Base Media**: QuickTime Movie with a fixed 2.0-second cue slot at `[1.0s, 3.0s]` and room-tone silence at `[0.0s, 0.5s]`.
- **Synthesized Audio Buffers (`AVAudioPCMBuffer`)**:
  - `case shorter`: 1.5-second buffer ($-25\%$ shorter). Validates that $0.5$s of room tone is sampled and crossfade-padded to exactly fill the $2.0$s slot.
  - `case minorOverflow`: 2.08-second buffer ($+4\%$ overflow). Validates automatic pitch-preserving compression using `AVAudioUnitTimePitch` at playback rate $1.04$.
  - `case boundaryOverflow`: 2.16-second buffer ($+8\%$ overflow). Validates the upper boundary of automatic pitch-preserving compression.
  - `case majorOverflow`: 2.30-second buffer ($+15\%$ overflow). Validates that the system halts automated processing and triggers the gated manual overflow state ($+0.30$s delta).

---

## 4. Invariant Assertion Matrix

Every test suite strictly verifies the following non-negotiable invariants:

| Invariant | Mathematical Formulation | Verification Method |
|-----------|--------------------------|---------------------|
| **1. Fixed-Slot Boundaries** | $t_{start}(Cue_{N+1})^{(after)} = t_{start}(Cue_{N+1})^{(before)}$ | CoreMedia `CMTimeCompare` equality check across edits |
| **2. Zero-Gap Splitting** | $t_{end}(Cue_A) = t_{start}(Cue_B) = t_{split}$ | Exact rational timestamp identity; zero overlap, zero gap |
| **3. Bitstream Payload Identity** | $SHA256(Payload_{export}) = SHA256(Payload_{source})$ | Hash comparison of extracted compressed `CMSampleBuffer` bytes |
| **4. Container Duration Matching** | $\Delta t_{container} = \lvert Dur_{export} - Dur_{source} \rvert \le \frac{1}{SampleRate}$ | Media duration difference bounded to $\le 1$ audio sample |
| **5. Zero Credential Leakage** | $\forall k \in Keys: k \notin project.json \land k \notin logs$ | AST/regex credential leak scanner over `.amend` bundle |

---

## 5. Running the Test Suites

Amend uses the native **Swift Testing** framework (`import Testing`, `@Suite`, `@Test`, `#expect`).

### Test Execution Commands
```bash
# Run all deterministic tests
swift test --no-parallel

# Run only Tier 1 Feature Coverage tests
swift test --filter Tier1FeatureTests

# Run only Project Format tests
swift test --filter AmendProjectFormatTests

# Run Security Suite tests
swift test --filter SecuritySuiteTests

# Run Storage & APFS tests
swift test --filter StorageAPFSTests

# Run opt-in Apple Foundation Models grammar tests
AMEND_RUN_APPLE_MODEL_TESTS=1 swift test --filter AppleFoundationGrammarTests

# Run opt-in local PocketTTS acceptance tests
AMEND_RUN_LOCAL_AI_TESTS=1 swift test --filter PocketTTSAcceptanceTests
```

### Environment Prerequisites
- **macOS Version**: macOS 26.0 or newer.
- **Architecture**: Apple Silicon (arm64).
- **Toolchain**: Swift 6.0+ (Swift tools version 6.0) with SwiftPM.
- **Security**: macOS Keychain available for test credentials (`com.fady.amend`).
