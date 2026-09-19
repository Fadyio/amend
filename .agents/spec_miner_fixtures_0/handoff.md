# Verification & Fixtures Specification Report

## Features Discovered

| # | Category | Feature | Description | Inputs | Outputs | Error Behavior | Discovered Via |
|---|----------|---------|-------------|--------|---------|----------------|----------------|
| 1 | Synthetic Fixtures | Fixture 1: Single-Track Deterministic Video | Programmatically generated 10–20s video with burned-in SMPTE timecode frames and single audio track with tone bursts and silence regions. | Duration (10–20s), FPS (30/29.97), tone freq (440Hz), burst/silence intervals. | AVAsset / MP4 file with 1 video track + 1 audio track. | Invalid duration or nil pixel buffer throws asset creation failure. | ORIGINAL_REQUEST.md:90-91, ADR 0007 |
| 2 | Synthetic Fixtures | Fixture 2: Multi-Track Video Asset | Synthetic video with Track 1 (narration tone bursts) and Track 2 (continuous background noise/hum). | Duration, video spec, Track 1 tone parameters, Track 2 noise parameters. | AVAsset / MP4 file with 1 video track + 2 audio tracks. | Writer failure if multi-track channel configuration mismatches. | ORIGINAL_REQUEST.md:92, ADR 0003, ADR 0007 |
| 3 | Synthetic Fixtures | Fixture 3: Duration Fitting Assets | Set of replacement audio clips matching fixed cue slot at shorter, +4%, +8%, and +15% duration deltas. | Target slot duration $D_{slot}$, replacement audio files at $-37.5\%$, $+4\%$, $+8\%$, $+15\%$. | Rendered/padded audio clips for slot alignment testing. | Unsupported sample rates or channel counts trigger converter error. | ORIGINAL_REQUEST.md:93, ADR 0005, ADR 0006 |
| 4 | Test Suites | Sync Invariant Suite | Formal regression suite asserting cue start and end timestamps remain immutable across text edits, splits, and re-renders. | Cue list, target cue index $N$, mutation action (edit text, re-synthesize, split). | Boolean assertion: $\forall k \ne N$, $C_k.\text{start}$ & $C_k.\text{end}$ identical. | Drift $>0$ rational ticks triggers immediate XCTest failure. | ORIGINAL_REQUEST.md:94, R2:37-43, ADR 0001 |
| 5 | Test Suites | Sample Payload Identity Test | Verification that AVAssetReader/Writer export pipeline passes compressed video samples bit-for-bit without re-encoding. | Source AVAsset, export output URL. | CMSampleBuffer count, PTS, DTS, duration, SHA-256 payload match. | Sample count mismatch or payload hash discrepancy triggers failure. | ORIGINAL_REQUEST.md:95, R6:59-67, ADR 0008 |
| 6 | Test Suites | Memory Lifecycle Test | Instrumentation test ensuring sequential execution of ASR, LLM, and PocketTTS within 8 GB RAM budget without swapping. | LocalModelCoordinator instance, full transcription and synthesis workflow. | Resident memory footprint measurements, model residency state assertions. | Simultaneous residency or memory footprint exceeding budget fails test. | ORIGINAL_REQUEST.md:96, R8:80-87, ADR 0009 |
| 7 | Test Suites | Security Suite | macOS Keychain round-trip validation and project bundle AST credential leak scanner. | Service keys (ElevenLabs, Resemble, Gemini), project bundle directory URL. | Keychain CRUD success, zero plaintext key matches in bundle JSON. | Keychain OSStatus error or regex match of API key in project.json fails test. | ORIGINAL_REQUEST.md:97, R3:48, R5:54, AC 123 |
| 8 | E2E Framework | Tier 1: Core Feature Coverage | Minimum 5 happy-path test cases per functional feature area (R1–R8). | Standard valid inputs per feature. | Expected feature outputs conforming to functional contracts. | Any contract violation fails suite. | ORIGINAL_REQUEST.md:88-98, Prompt Mission |
| 9 | E2E Framework | Tier 2: Boundary & Corner Cases | Minimum 5 stress, boundary, and edge test cases per feature area (R1–R8). | Zero-length, threshold boundary ($\pm 0.01\%$), extreme zoom, non-APFS, VFR. | Robust error handling, exact threshold enforcement, zero crash/drift. | Unhandled error or precision rounding fails test. | ORIGINAL_REQUEST.md:28-87, Prompt Mission |
| 10 | E2E Framework | Tier 3: Cross-Feature Pairwise | Integration tests verifying pairwise interactions between independent subsystems. | Pairwise combinations (e.g. Import $\times$ Export, Fitting $\times$ Passthrough Mux). | Compositional integrity, multi-track bitstream alignment. | State corruption or race conditions fail test. | ORIGINAL_REQUEST.md:28-87, Prompt Mission |
| 11 | E2E Framework | Tier 4: Real-World Scenarios | Minimum 5 realistic end-to-end user recording workflows simulating developer use cases. | Full demo recordings, transcript workflows, overflow gates, cross-volume storage. | Complete exported video identical in length and action sync to source. | Playback/export de-sync or visual stutter fails test. | ORIGINAL_REQUEST.md:28-87, Prompt Mission |
| 12 | Timeline / UI | Frame-Accurate Playhead & SMPTE Ruler | Continuous CMTime playhead with SwiftTimecode SMPTE conversion and independent audio/video time resolution. | CMTime playhead position, pixelsPerSecond zoom factor. | Visual playhead position, SMPTE display string, frame-accurate video presentation. | Negative time or invalid timescale clamped cleanly. | ORIGINAL_REQUEST.md:28-36, AC 102-105 |
| 13 | Composition Engine | Cue Splitting Zero-Gap Invariant | Splitting cue $[t_s, t_e]$ at playhead $t$ produces $[t_s, t]$ and $[t, t_e]$ with zero gap and zero overlap. | Cue $C$, split timestamp $t \in (t_s, t_e)$. | Cues $C_A, C_B$ where $C_A.\text{end} == C_B.\text{start} == t$. | $t \le t_s$ or $t \ge t_e$ throws invalidSplitPoint error. | ORIGINAL_REQUEST.md:41, AC 115 |
| 14 | Media Import | Ambiguity-Safe Audio Track Mapping | Automated track discovery with single-track advisory badge or multi-track assignment modal. | Source AVAsset audio tracks array. | Track designation: Narration track index + Passthrough track indices set. | 0 audio tracks displays error alert; unassigned tracks blocked from export. | ORIGINAL_REQUEST.md:46, ADR 0003, AC 108-109 |
| 15 | Project Storage | APFS Clone-First Media Bundling | Destination volume inspection for volumeSupportsFileCloning: copyItem vs security-scoped bookmark. | Source media URL, destination .amend bundle URL. | Cloned media inside bundle or externalBookmark in project.json. | Non-clonable volume copying large file triggers fallback, not full copy. | ORIGINAL_REQUEST.md:47-48, ADR 0004, AC 110-111 |
| 16 | Duration Fitting | Room-Tone Padding Engine | Sampling 200–500ms ambient silence slice via Silero VAD to pad shorter synthesized audio with 10–20ms crossfades. | Shorter synthesized audio, sampled room tone slice, target slot CMTimeRange. | Rendered audio buffer of exact slot duration with seamless acoustic bed. | Absence of VAD silence falls back to generated dithered noise floor. | ORIGINAL_REQUEST.md:54-55, ADR 0005, AC 119 |
| 17 | Duration Fitting | Automatic Pitch-Preserving Compression | Offline AVAudioUnitTimePitch compression for speech exceeding duration by $\le 8\%$. | Synthesized audio, target slot duration ($\Delta \le +8\%$). | Compressed audio matching slot duration; pitch shift == 0 cents. | Compression $>8\%$ rejected; triggers overflow state. | ORIGINAL_REQUEST.md:56, ADR 0006, AC 120 |
| 18 | Duration Fitting | Gated Manual Overflow Controller | Strict manual gating for speech exceeding duration by $>8\%$, presenting exact overflow delta and 3 actions. | Synthesized audio with $\Delta > +8\%$. | UI state presenting exact $+\Delta t$, [Rewrite to Fit], [Force Fit], [Split Cue]. | Automated retry loop strictly forbidden; throws if loop attempted. | ORIGINAL_REQUEST.md:57, ADR 0006, AC 121 |
| 19 | Export Engine | Compressed-Sample Video Remuxing | AVAssetReaderTrackOutput(outputSettings: nil) to AVAssetWriterInput passthrough muxer. | Source video track, destination container format hint. | Muxed video stream with unchanged sample payloads and presentation timestamps. | Reader/writer pipeline failure reported without silent fallback to transcoding. | ORIGINAL_REQUEST.md:59-67, ADR 0008, AC 131-134 |
| 20 | Model Lifecycle | Serialized LocalModelCoordinator | Singleton coordinator ensuring mutual exclusion between Parakeet ASR, local LLM, and PocketTTS. | Model activation requests (.asr, .llm, .tts). | Loaded model handle; evicted previous models; intermediate disk cache. | Out-of-order activation queued; concurrent residency throws invariant error. | ORIGINAL_REQUEST.md:80-87, ADR 0009, AC 136-137 |

---

## Edge Cases

| # | Feature | Input | Observed / Required Behavior |
|---|---------|-------|------------------------------|
| 1 | Sync Invariant | Cue edit on last cue in timeline | Last cue duration changes must not alter total video duration or any prior cue boundaries $[C_0 \dots C_{N-1}]$. |
| 2 | Sync Invariant | Multiple consecutive splits at identical timestamp | First split succeeds; second split at boundary $t=C_A.\text{end}$ throws `zeroDurationCue` error. |
| 3 | Sync Invariant | Rapid successive edits across 50 cues | All cue boundaries maintain exact rational CMTime values without floating point drift or accumulation error. |
| 4 | Sample Payload Identity | Source media with non-standard timescale (e.g. 29.97 fps with 30000/1001 timescale) | Reader/writer maintains exact timescale and sample duration fractions; exported file matches source byte-for-byte. |
| 5 | Sample Payload Identity | Variable Frame Rate (VFR) source video | Reader/writer preserves individual sample PTS/DTS without forcing constant frame rate (CFR) interpolation. |
| 6 | Duration Fitting | Replacement audio duration delta $\Delta = +8.000\%$ exact boundary | Processed via automatic `AVAudioUnitTimePitch` compression without user intervention. |
| 7 | Duration Fitting | Replacement audio duration delta $\Delta = +8.001\%$ (exceeds threshold by 1ms) | Must NOT auto-compress; enters User-Gated Overflow state displaying exact $+\Delta t$. |
| 8 | Duration Fitting | Replacement audio duration delta $\Delta = -99.9\%$ (single syllable in 10s cue) | Audio played at natural cadence at cue start; remaining 9.9s filled with looped, crossfaded room tone. |
| 9 | Duration Fitting | Source recording with zero detectable silence (<200ms VAD silence throughout) | Room tone sampler falls back to lowest-energy 200ms frame with dither to prevent digital black clicks. |
| 10 | Duration Fitting | User selects `[Force Fit]` on +30% overflow | Extreme time-compression executed explicitly by user override; warning badge displayed on cue slot. |
| 11 | Audio Track Import | Source video with 0 audio tracks | System presents informative error banner: "No audio tracks detected in media"; editing disabled. |
| 12 | Audio Track Import | Source video with 8 discrete audio tracks (e.g. multi-mic podcast / screen recording) | Track Picker modal displays all 8 tracks; allows designating 1 Narration track and up to 7 Passthrough tracks. |
| 13 | APFS Storage | Source video located on FAT32/exFAT external USB drive | `volumeSupportsFileCloning` returns `false`; creates security-scoped bookmark in `project.json`; zero full copy. |
| 14 | APFS Storage | Source video moved or renamed after project creation with bookmark | App prompts user to re-locate media via standard macOS open panel; updates security-scoped bookmark. |
| 15 | Model Lifecycle | Transcription initiated while PocketTTS voice cloning model is active | Coordinator terminates/unloads PocketTTS, reclaims RAM, then loads Parakeet Core ML ASR. |
| 16 | Model Lifecycle | Low memory warning received from macOS kernel (`OSMemoryNotification`) | Coordinator immediately drops in-memory token/WAV caches (relying on disk cache) and unloads idle models. |
| 17 | Security Suite | Keychain item already exists during save | System performs `SecItemUpdate` instead of failing with `errSecDuplicateItem`. |
| 18 | Security Suite | Project bundle exported / packaged into zip | Verify zip archive and internal `project.json` contain no API keys, secrets, or user home directory absolute paths. |
| 19 | Grammar Diff | AI rewrite returns text identical to current narration | System detects zero diff; displays "No changes needed" toast without prompting user for replacement. |
| 20 | Grammar Diff | AI rewrite contains backticks, code snippets (`func foo()`), or numbers (`42`) | Grammar provider preserves exact identifiers, syntax, and numbers; diff modal highlights prose modifications. |

---

# Detailed Technical Specifications

## Part 1: The 3 Synthetic AVFoundation Verification Fixtures

### Fixture 1: Single-Track Deterministic Video
* **Purpose**: Primary baseline fixture testing single-track media loading, audio extraction, waveform generation, cue segmentation, timecode alignment, and sample payload passthrough.
* **Container**: MPEG-4 (`.mp4`) or QuickTime Movie (`.mov`).
* **Duration**: Exactly $15.000$ seconds ($15000 / 1000$ seconds, $9000 / 600$ CMTime).
* **Video Track**:
  - Codec: H.264 / AVC (`avc1`) or HEVC (`hvc1`).
  - Dimensions: $1920 \times 1080$ progressive.
  - Frame Rate: $30.0$ fps (frame duration: $\text{CMTime}(value: 1, timescale: 30)$ or $\text{CMTime}(value: 20, timescale: 600)$).
  - Total Video Frames: Exactly $450$ frames.
  - Visual Content (Burned-in):
    - Each frame rendered programmatically via `CVPixelBuffer` + Core Graphics.
    - Large high-contrast text centered displaying exact SMPTE timecode: `00:00:00:00` through `00:00:14:29`.
    - Secondary text line displaying: `Frame: N / 450 | Time: X.XXXs`.
    - Corner flashing visual sync blip (white square on frame 0, 30, 60, ...; black square otherwise) for optical sync validation.
* **Audio Track**:
  - Quantity: Exactly 1 audio track.
  - Format: Linear PCM (`lpcm`, 16-bit signed integer or 32-bit float) or AAC (`mp4a`), 48,000 Hz sample rate, Stereo or Mono.
  - Pattern: Deterministic alternating tone bursts and silence regions:
    - Region 1 ($0.0s - 2.0s$): 440 Hz Sine wave tone burst at -12 dBFS (Simulating Cue 1).
    - Region 2 ($2.0s - 3.0s$): Ambient silence with low-level dither (-60 dBFS) for 1.0s (Simulating pause / room tone).
    - Region 3 ($3.0s - 7.0s$): 880 Hz Sine wave tone burst at -12 dBFS (Simulating Cue 2, duration 4.0s).
    - Region 4 ($7.0s - 8.0s$): Ambient silence with low-level dither (-60 dBFS) for 1.0s (Simulating pause / room tone).
    - Region 5 ($8.0s - 13.0s$): 440 Hz Sine wave tone burst at -12 dBFS (Simulating Cue 3, duration 5.0s).
    - Region 6 ($13.0s - 15.0s$): Digital silence for 2.0s (End padding).
* **Deterministic Verification Hooks**:
  - Loading media without transcoding (Acceptance Criteria 102).
  - Player playhead seeking to frame-accurate SMPTE stamps.
  - DSWaveformImage extraction yielding known peak/RMS envelopes at tone burst intervals.
  - Single-track advisory badge verification (Acceptance Criteria 108).

### Fixture 2: Multi-Track Deterministic Video
* **Purpose**: Test ambiguity-safe audio track detection, interactive Track Picker routing, independent passthrough muxing, and untouched preservation of secondary audio streams.
* **Container**: QuickTime Movie (`.mov`) or MPEG-4 (`.mp4`).
* **Duration**: Exactly $15.000$ seconds.
* **Video Track**: Identical to Fixture 1 (450 frames @ 30 fps with embedded timecode).
* **Audio Track 1 (Narration Candidate)**:
  - Format: Linear PCM / AAC, 48,000 Hz, Mono.
  - Pattern: 440 Hz tone bursts matching spoken speech cadence (e.g. bursts at $0-3s$, $4-8s$, $9-14s$ with inter-burst silence).
* **Audio Track 2 (Background / System Audio Candidate)**:
  - Format: Linear PCM / AAC, 48,000 Hz, Stereo.
  - Pattern: Continuous 120 Hz low-frequency drone combined with subtle broadband pink noise at -24 dBFS spanning the entire $15.000$ seconds without silence gaps.
* **Deterministic Verification Hooks**:
  - Multi-track discovery: Media import detects `asset.tracks(withMediaType: .audio).count == 2`.
  - Track Picker presentation: Verifies UI/engine prompts for track designation.
  - Passthrough integrity: After replacing narration in Track 1, Track 2 is verified bit-for-bit identical in the exported container (same sample count, presentation timestamps, and SHA-256 payload checksums).

### Fixture 3: Duration Fitting Test Assets
* **Purpose**: Test the asymmetric duration fitting engine across all four duration regimes (shorter, $+4\%$, $+8\%$, $+15\%$).
* **Baseline Cue Slot**:
  - Target Slot Duration: $D_{slot} = 4.000$ seconds ($\text{CMTime}(value: 4000, timescale: 1000)$), spanning $t = [3.000s, 7.000s]$.
  - Ambient Room Tone Slice: $300$ ms audio buffer sampled from silence region ($2.0s - 2.3s$) of Fixture 1.
* **Replacement Audio Clips**:
  1. **Clip A (Shorter Speech, $-37.5\%$)**:
     - Raw Duration: $2.500$ seconds ($2500$ ms).
     - Expected Behavior: Audio plays at natural tempo ($1.0\times$) starting at $t=3.000s$.
     - Room Tone Padding: Residual $1.500$ seconds ($4.000s - 2.500s$) is filled with looped, crossfaded ambient room tone.
     - Boundary Crossfades: $15$ ms equal-power crossfade applied between speech tail and room tone head, and at slot boundaries.
     - Assertion: Total rendered slot audio duration == exactly $4.000$ seconds ($192,000$ samples @ 48kHz).
  2. **Clip B (Mild Overflow, $+4\%$)**:
     - Raw Duration: $4.160$ seconds ($4160$ ms, overflow $= +160$ ms).
     - Expected Behavior: Exceeds slot duration by $+4\% \le 8\%$.
     - Processing: Automatically time-compressed via `AVAudioUnitTimePitch` with playback rate $R = 4.160 / 4.000 = 1.040$. Pitch shift remains strictly $0$ cents.
     - Assertion: Rendered slot audio duration == exactly $4.000$ seconds; vocal pitch unaltered.
  3. **Clip C (Boundary Overflow, $+8\%$)**:
     - Raw Duration: $4.320$ seconds ($4320$ ms, overflow $= +320$ ms).
     - Expected Behavior: Exactly at the $+8.00\%$ automatic compression boundary limit.
     - Processing: Automatically time-compressed via `AVAudioUnitTimePitch` with playback rate $R = 4.320 / 4.000 = 1.080$. Pitch shift remains strictly $0$ cents.
     - Assertion: Rendered slot audio duration == exactly $4.000$ seconds.
  4. **Clip D (Excessive Overflow, $+15\%$)**:
     - Raw Duration: $4.600$ seconds ($4600$ ms, overflow $= +600$ ms).
     - Expected Behavior: Exceeds slot duration by $+15\% > 8\%$.
     - Processing: Must NOT automatically time-compress. Must NOT enter autonomous LLM retry loop.
     - UI / Engine State: Transitions to `GatedManualOverflow` state.
     - Output / Assertions:
       - Displays exact overflow: `+0.60s`.
       - Exposes three explicit manual actions: `[Rewrite to Fit]`, `[Force Fit]`, `[Split Cue]`.
       - Retry loop counter == 0 (no recursive or background re-synthesis calls).

---

## Part 2: Required Test Suites

### 1. Sync Invariant Suite
* **Source References**: ORIGINAL_REQUEST.md:37-43, 94; ADR 0001; Acceptance Criteria 114-117.
* **Core Principle**: Video timestamps belong exclusively to the video timeline. Editing narration or replacing audio in cue $N$ cannot alter the temporal boundaries of any cue in the timeline.
* **Mathematical Invariant Specification**:
  Let $T = [C_0, C_1, \dots, C_{M-1}]$ be an ordered list of contiguous or non-contiguous cues on the timeline, where each cue $C_i$ has:
  $$C_i.\text{timeRange} = [t_{s, i}, t_{e, i}), \quad \text{duration}(C_i) = t_{e, i} - t_{s, i}$$
  For any timeline mutation operation $\mathcal{M}$ applied to cue $C_N$:
  1. **Non-Target Invariant**:
     $$\forall k \ne N, \quad C_k.\text{start}_{\text{after}} = C_k.\text{start}_{\text{before}} \quad \land \quad C_k.\text{end}_{\text{after}} = C_k.\text{end}_{\text{before}}$$
  2. **Target Slot Invariant**:
     $$C_N.\text{start}_{\text{after}} = C_N.\text{start}_{\text{before}} \quad \land \quad C_N.\text{end}_{\text{after}} = C_N.\text{end}_{\text{before}}$$
  3. **Rendered Audio Duration Invariant**:
     $$\text{duration}(\text{RenderedAudio}(C_N)) = C_N.\text{end} - C_N.\text{start}$$
  4. **Split Cue Invariant**:
     For a split of cue $C_N = [t_s, t_e)$ at timestamp $t_{\text{split}} \in (t_s, t_e)$:
     $$C_{N, A} = [t_s, t_{\text{split}}), \quad C_{N, B} = [t_{\text{split}}, t_e)$$
     $$C_{N, A}.\text{start} = t_s, \quad C_{N, A}.\text{end} = C_{N, B}.\text{start} = t_{\text{split}}, \quad C_{N, B}.\text{end} = t_e$$
     $$\text{Gap} = C_{N, B}.\text{start} - C_{N, A}.\text{end} = 0$$
     $$\forall k > N, \quad C_k.\text{start}_{\text{after}} = C_k.\text{start}_{\text{before}}$$
* **Rational Precision Rule**:
  All assertions must be performed using exact rational `CMTime` comparisons:
  ```swift
  XCTAssertEqual(CMTimeCompare(cueAfter.timeRange.start, cueBefore.timeRange.start), 0)
  XCTAssertEqual(CMTimeCompare(cueAfter.timeRange.duration, cueBefore.timeRange.duration), 0)
  ```
  Floating-point approximations (e.g. `Double(cmTime.seconds) == Double(...)`) or SMPTE frame-rounded timestamps are strictly prohibited in boundary assertions.

### 2. Sample Payload Identity Test
* **Source References**: ORIGINAL_REQUEST.md:59-67, 95; ADR 0008; Acceptance Criteria 131-134.
* **Core Principle**: The video export pipeline must pass compressed video samples directly from reader to writer without decoding, transcoding, or frame recalculation.
* **Pipeline Architecture Under Test**:
  $$\text{Source File} \xrightarrow{\text{AVAssetReaderTrackOutput(outputSettings: nil)}} \text{Compressed } \text{CMSampleBuffer} \xrightarrow{\text{AVAssetWriterInput(outputSettings: nil)}} \text{Exported File}$$
* **Test Verification Procedure**:
  1. Initialize `AVAssetReader` with `AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)` on Fixture 1.
  2. Extract all $K$ video sample buffers into an array of source descriptors:
     ```swift
     struct SampleDescriptor {
         let pts: CMTime
         let dts: CMTime
         let duration: CMTime
         let flags: CMSampleBufferFlags
         let payloadSHA256: String
     }
     ```
  3. Execute `amend` export pipeline producing `Exported.mp4`.
  4. Initialize `AVAssetReader` on `Exported.mp4` with `outputSettings: nil`.
  5. Extract all $K'$ exported video sample buffers into exported descriptors.
  6. Assertions:
     - Sample Count Identity: $K' == K == 450$.
     - Per-sample Temporal Identity: $\forall i \in [0, K-1]$:
       $$\text{PTS}_{\text{export}}[i] == \text{PTS}_{\text{source}}[i]$$
       $$\text{DTS}_{\text{export}}[i] == \text{DTS}_{\text{source}}[i]$$
       $$\text{Duration}_{\text{export}}[i] == \text{Duration}_{\text{source}}[i]$$
     - Per-sample Bitstream Identity:
       $$\text{SHA256}(\text{BlockBufferBytes}_{\text{export}}[i]) == \text{SHA256}(\text{BlockBufferBytes}_{\text{source}}[i])$$
     - Codec & Metadata Identity: Codec type (`kCMVideoCodecType_H264`), dimensions ($1920 \times 1080$), and container duration match source file exactly.

### 3. Memory Lifecycle Test
* **Source References**: ORIGINAL_REQUEST.md:80-87, 96; ADR 0009; Acceptance Criteria 136-137.
* **Core Principle**: On 8 GB Apple Silicon devices, Core ML models cannot be held in memory simultaneously. ASR, LLM, and TTS models must be strictly serialized and evicted from RAM when inactive.
* **Coordinator State Machine Under Test**:
  $$\text{Idle} \xrightarrow{\text{transcribe()}} \text{ASR Loaded} \xrightarrow{\text{transcription done}} \text{ASR Evicted} \xrightarrow{\text{synthesize()}} \text{TTS Loaded} \xrightarrow{\text{synthesis done}} \text{TTS Evicted} \xrightarrow{} \text{Idle}$$
* **Test Verification Procedure**:
  1. Instantiate `LocalModelCoordinator`.
  2. Trigger ASR transcription on a 30s audio segment using Parakeet Core ML + Silero VAD:
     - Assert `LocalModelCoordinator.isLoaded(.asr) == true`.
     - Assert `LocalModelCoordinator.isLoaded(.tts) == false`.
     - Assert `LocalModelCoordinator.isLoaded(.llm) == false`.
     - Measure resident memory footprint via `mach_task_basic_info`.
  3. Complete transcription:
     - Coordinator writes transcript tokens to disk cache.
     - Coordinator unloads ASR model.
     - Assert `LocalModelCoordinator.isLoaded(.asr) == false`.
  4. Trigger local voice cloning synthesis via PocketTTS:
     - Coordinator loads PocketTTS weights.
     - Assert `LocalModelCoordinator.isLoaded(.tts) == true`.
     - Assert `LocalModelCoordinator.isLoaded(.asr) == false`.
     - Assert `LocalModelCoordinator.isLoaded(.llm) == false`.
  5. Peak Memory & Leak Checks:
     - Measure peak physical resident memory throughout workflow:
       $$\text{Peak RAM} \le 3.5 \text{ GB}$$
       (Leaves ample headroom for macOS system services within 8 GB hardware budget).
     - Repeat cycle 3 times: assert baseline RAM returns to idle levels ($\le 250$ MB delta) with zero Core ML memory leaks.

### 4. Security Suite
* **Source References**: ORIGINAL_REQUEST.md:48, 54, 97; Acceptance Criteria 123.
* **Core Principle**: Cloud API credentials must never be stored in plain text, must never touch project files, and must reside exclusively in macOS Keychain.
* **Test Verification Procedure**:
  1. **Keychain Round-Trip Test**:
     - Define test keys for providers: ElevenLabs (`sk_test_11labs_xyz`), Resemble (`resemble_test_token_abc`), Gemini (`AIzaSyTestGeminiKey123`).
     - Save credentials via Keychain wrapper utilizing `kSecClassGenericPassword` with service identifier `com.fady.amend.credentials.<provider>`.
     - Verify `SecItemAdd` returns `errSecSuccess`.
     - Read back credentials: verify returned string matches original plain text.
     - Update credentials: verify `SecItemUpdate` updates secret without duplication.
     - Delete credentials: verify `SecItemDelete` removes entry and subsequent read returns `errSecItemNotFound`.
  2. **Project Bundle Sanitization Scanner**:
     - Create a complete `.amend` project bundle containing edited cues, cached waveforms, thumbnails, and provider configurations (e.g. provider selected: "ElevenLabs", voice ID: "21m00Tcm4TlvDq8ikWAM").
     - Recursively inspect all files in `Project.amend/`:
       - `project.json`
       - Cache files, log files, and metadata plists.
     - Parse JSON AST and perform regex pattern matching against:
       - Generic token keys: `(?i)(api[_-]?key|secret|token|password|bearer|auth)`
       - Provider-specific key patterns: `sk_[a-zA-Z0-9]{32,}`, `AIza[0-9A-Za-z-_]{35}`, etc.
     - Assert zero matches across all project bundle contents.
     - Assert `project.json` stores only provider enum and voice identifier, with all auth retrieved on-demand from Keychain.

---

## Part 3: E2E 4-Tier Testing Framework Requirements

### Tier 1: Feature Coverage ($\ge 5$ test cases per feature across R1–R8)

#### Feature R1: Video Playback & Synchronized Timeline
1. `test_timeline_initialization_without_transcoding`: Verifies player loads MP4/MOV and enters ready-to-play state without invoking export/transcode sessions.
2. `test_playhead_continuous_cmtime_tracking`: Verifies playhead scrub updates CMTime continuously with nanosecond timescale accuracy.
3. `test_frame_accurate_video_seeking`: Verifies seeking to arbitrary CMTime displays the exact video frame matching SMPTE calculation.
4. `test_filmstrip_thumbnail_generation`: Verifies `AVAssetImageGenerator` asynchronously produces thumbnails at requested time intervals.
5. `test_waveform_dynamic_zoom_scaling`: Verifies `DSWaveformImage` analyzer scales normalized waveform bins proportionally when `pixelsPerSecond` changes.

#### Feature R2: Fixed-Slot Audio Invariant & Composition Engine
1. `test_cue_boundary_immutability_on_text_edit`: Modifies text in Cue 0; asserts Cue 1 start/end timestamps are unaltered.
2. `test_cue_boundary_immutability_on_audio_replacement`: Injects new audio into Cue 0; asserts Cue 1 start/end timestamps are unaltered.
3. `test_cue_split_zero_gap_and_overlap`: Splits Cue at playhead $t$; asserts $C_A.\text{end} == C_B.\text{start} == t$.
4. `test_slot_duration_equals_cmtimerange`: Renders modified cue; asserts rendered audio length equals slot duration.
5. `test_boundary_crossfade_smoothing`: Verifies 10–20ms crossfade envelopes are computed at cue transition boundaries.

#### Feature R3: Audio Track Import & Project Storage
1. `test_single_track_detection_advisory_badge`: Loads Fixture 1; asserts Narration auto-assigned and advisory badge flag is true.
2. `test_multi_track_detection_modal_routing`: Loads Fixture 2; asserts Track Picker modal triggered and requires user confirmation.
3. `test_passthrough_track_retention`: Designates Track 2 as Passthrough; verifies Track 2 included in playback composition.
4. `test_apfs_clone_detection_copyitem`: On APFS volume, verifies `volumeSupportsFileCloning` triggers `FileManager.copyItem` without duplicating allocated disk blocks.
5. `test_bookmark_fallback_on_non_clonable_volume`: Simulates external volume; verifies security-scoped bookmark generated and saved to `project.json`.

#### Feature R4: Word-Aligned Transcription & Cue Generation
1. `test_parakeet_asr_word_timestamp_extraction`: Transcribes narration audio; verifies each word token has valid start/end CMTime.
2. `test_silero_vad_speech_segmentation`: Runs Silero VAD; verifies silence gaps (>200ms) are detected and used to segment cues.
3. `test_cue_generation_from_transcription`: Validates generated cues completely partition speech intervals without overlaps.
4. `test_cue_click_seeks_video_playback`: Simulates cue click in UI model; verifies player seeks to cue start CMTime.
5. `test_playback_active_cue_highlighting`: Advances playhead; verifies active cue state transitions dynamically as playhead crosses cue boundaries.

#### Feature R5: Asymmetric Duration Fitting & Voice Synthesis
1. `test_shorter_speech_room_tone_padding`: Synthesizes audio shorter than slot; verifies natural cadence preserved and remainder padded with room tone.
2. `test_room_tone_sampling_from_vad_silence`: Verifies room tone sampler extracts 200–500ms slice from detected VAD silence region.
3. `test_auto_compression_within_eight_percent`: Synthesizes audio $+4\%$ longer; verifies `AVAudioUnitTimePitch` compresses to exact slot duration.
4. `test_gated_overflow_exceeding_eight_percent`: Synthesizes audio $+15\%$ longer; verifies system enters gated state and displays $+0.60s$ overflow.
5. `test_pocket_tts_local_voice_cloning`: Verifies PocketTTS synthesizes audio using Reference Voice sample without cloud network calls.

#### Feature R6: Compressed-Sample Passthrough Export Pipeline
1. `test_video_track_reader_writer_passthrough`: Exports Fixture 1; asserts video samples copied without decoding (`outputSettings: nil`).
2. `test_passthrough_audio_muxing`: Exports Fixture 2; asserts Passthrough Track 2 bitstream preserved bit-for-bit.
3. `test_modified_narration_audio_reencoding`: Replaces Cue 1 audio; asserts exported audio track re-encoded cleanly while video remains untouched.
4. `test_export_container_duration_identity`: Verifies exported file duration matches source media duration within 1 audio sample frame.
5. `test_passthrough_fast_path_selection`: Verifies `AVAssetExportPresetPassthrough` evaluated only when compatibility is verified.

#### Feature R7: Grammar Correction & Script Rewriting
1. `test_grammar_provider_diff_modal_presentation`: Submits Fix Grammar request; asserts text diff generated before applying change.
2. `test_rewrite_to_fit_passes_duration_constraints`: Requests Rewrite to Fit; verifies prompt includes target cue duration and speaking rate constraint.
3. `test_restore_original_transcript`: Applies AI rewrite; executes Restore Original; verifies initial transcript text restored.
4. `test_preserve_developer_code_identifiers`: Rewrites technical text; asserts symbols like `func processData()` and `HTTP 404` are preserved.
5. `test_llm_failure_does_not_block_manual_edits`: Simulates LLM network timeout; verifies manual text editing and synthesis remain fully functional.

#### Feature R8: Local Model Lifecycle for 8GB Apple Silicon
1. `test_asr_unloaded_before_tts_loaded`: Verifies Parakeet ASR model deallocated before PocketTTS initializes.
2. `test_heavyweight_inference_serialization`: Dispatches concurrent transcription and synthesis requests; asserts execution is serialized.
3. `test_transcription_token_disk_caching`: Verifies transcription results cached to disk and reloadable without re-running ASR.
4. `test_synthesized_wav_disk_caching`: Verifies synthesized cue WAVs stored in project bundle and reused across sessions.
5. `test_graceful_missing_model_handling`: Simulates missing Core ML model asset; verifies typed error thrown without project corruption.

---

### Tier 2: Boundary & Corner Cases ($\ge 5$ test cases per feature across R1–R8)

#### Feature R1: Video Playback & Synchronized Timeline
1. `test_playhead_scrub_past_video_duration`: Scrubbing past video end clamps playhead to exact video CMTime duration without crashing.
2. `test_playhead_scrub_negative_time`: Dragging playhead left of timeline origin clamps to `kCMTimeZero`.
3. `test_extreme_zoom_in_nanosecond_scale`: Timeline zoom set to maximum (`pixelsPerSecond = 10,000`); verified playhead render precision.
4. `test_extreme_zoom_out_overview`: Timeline zoom set to minimum (`pixelsPerSecond = 1`); verifies thumbnail and waveform generators don't OOM.
5. `test_zero_byte_or_truncated_video_file`: Loading 0-byte file throws specific `CorruptMediaFile` error without crashing player.

#### Feature R2: Fixed-Slot Audio Invariant & Composition Engine
1. `test_split_cue_at_exact_start_boundary`: Attempting to split Cue at $t = t_{start}$ throws `InvalidSplitPointException`.
2. `test_split_cue_at_exact_end_boundary`: Attempting to split Cue at $t = t_{end}$ throws `InvalidSplitPointException`.
3. `test_split_single_frame_duration_cue`: Splitting a cue with duration of 1 video frame (33ms) produces two sub-frame audio cues without numerical underflow.
4. `test_audio_replacement_with_zero_length_audio`: Attempting to replace cue audio with 0-byte WAV throws validation error; slot retained.
5. `test_rapid_successive_cues_with_zero_silence`: Adjacent cues with zero inter-cue silence render continuous audio without click artifacts.

#### Feature R3: Audio Track Import & Project Storage
1. `test_import_media_with_zero_audio_tracks`: Source video has 0 audio tracks; presents advisory warning and blocks audio editing features.
2. `test_import_media_with_eight_audio_tracks`: Source video has 8 audio tracks; Track Picker handles all tracks without UI truncation.
3. `test_read_only_filesystem_import`: Project bundle creation on read-only filesystem fails gracefully with permissions error.
4. `test_non_apfs_network_smb_import`: Import from network share detects cloning unsupported; generates bookmark without freezing UI.
5. `test_source_media_file_moved_between_sessions`: Reopening project where source media was renamed triggers security-scoped bookmark resolution dialog.

#### Feature R4: Word-Aligned Transcription & Cue Generation
1. `test_transcription_on_completely_silent_audio`: Audio track contains pure digital silence; ASR produces 0 cues; displays empty transcript state.
2. `test_transcription_on_continuous_speech_without_pauses`: 15s uninterrupted rapid speech; Silero VAD creates logical cues at sentence/phrase boundaries.
3. `test_transcription_with_heavy_background_noise`: Narration at -10 dBFS with background noise at -12 dBFS; VAD segments speech correctly.
4. `test_word_boundary_at_exact_timeline_zero`: First spoken word starts at $t = 0.000s$; cue generated with $t_{start} = \text{kCMTimeZero}$.
5. `test_special_characters_and_foreign_terms_transcription`: Narration containing technical terms (e.g. `kSecClassGenericPassword`); words aligned accurately.

#### Feature R5: Asymmetric Duration Fitting & Voice Synthesis
1. `test_duration_fitting_at_exact_eight_percent_limit`: Synthesized duration is $+8.000\%$; automatically compressed via time pitch unit.
2. `test_duration_fitting_at_eight_point_zero_one_percent`: Synthesized duration is $+8.010\%$; strictly triggers gated overflow modal.
3. `test_duration_fitting_ultra_short_single_syllable`: 100ms utterance in 5.0s cue; room tone fills 4.9s with smooth crossfades and zero acoustic drop.
4. `test_room_tone_sampling_with_clipping_source`: Source narration has peak clipping; room tone sampler ignores clipped regions.
5. `test_force_fit_on_fifty_percent_overflow`: User explicitly forces fit on $+50\%$ overflow; audio compressed with warning badge; slot bounds preserved.

#### Feature R6: Compressed-Sample Passthrough Export Pipeline
1. `test_export_vfr_video_preserving_variable_pts`: Variable frame rate video preserves exact non-uniform presentation timestamps.
2. `test_export_video_with_non_standard_timescale`: Video with timescale $12,800$ or $90,000$ exports without timescale distortion.
3. `test_export_when_disk_space_exhausted`: Destination disk fills up during export; pipeline aborts cleanly and removes partial export file.
4. `test_export_with_unsupported_passthrough_audio_container`: Incompatible audio track triggers re-encoding of audio while keeping video compressed passthrough.
5. `test_export_with_cancelled_operation`: User cancels export midway; reader/writer pipelines terminate immediately without resource leaks.

#### Feature R7: Grammar Correction & Script Rewriting
1. `test_grammar_rewrite_preserving_code_blocks`: Text containing Markdown code block (`\`\`\`swift ... \`\`\``) retains code syntax verbatim.
2. `test_grammar_rewrite_preserving_urls_and_file_paths`: Text containing `/usr/local/bin` and `https://apple.com` retains paths and URLs.
3. `test_grammar_rewrite_with_empty_string`: Submitting empty cue text to rewrite provider returns validation error without sending LLM request.
4. `test_network_disconnect_during_gemini_rewrite`: Internet disconnected during cloud Gemini call; returns typed network error; original text preserved.
5. `test_grammar_diff_with_only_punctuation_changes`: AI changes comma to semicolon; diff modal renders punctuation diff cleanly.

#### Feature R8: Local Model Lifecycle for 8GB Apple Silicon
1. `test_rapid_toggle_between_asr_and_tts`: Rapidly alternating between transcription and synthesis requests serializes cleanly without deadlock.
2. `test_kernel_memory_pressure_notification`: Simulates `OSMemoryPressure` notification; coordinator purges memory caches immediately.
3. `test_corrupt_coreml_model_file_on_disk`: Model weight file corrupted; coordinator reports download/verify error; doesn't crash app.
4. `test_background_synthesis_cancelled_midway`: User cancels cue synthesis while PocketTTS is computing; thread stops promptly and frees resources.
5. `test_local_model_allocation_respects_process_limit`: Validates process physical footprint never exceeds $3.5$ GB across all test runs.

---

### Tier 3: Cross-Feature Pairwise Interactions

1. **Pair 1: Audio Track Import (R3) $\times$ Passthrough Export (R6)**
   - *Interaction*: Source video with 2 audio tracks (Fixture 2). Track 1 designated Narration, Track 2 designated Passthrough. Export pipeline executed.
   - *Assertion*: Video samples pass through untouched. Modified narration audio encodes to Track 1. Passthrough Track 2 matches source Track 2 sample-for-sample, bit-for-bit.
2. **Pair 2: Word-Aligned Transcription (R4) $\times$ Fixed-Slot Composition (R2)**
   - *Interaction*: FluidAudio transcribes narration into 25 adjacent cues. User performs 5 consecutive cue splits and 3 text modifications.
   - *Assertion*: All cue boundaries maintain zero-gap invariant; no downstream cues shift in time.
3. **Pair 3: Duration Fitting (R5) $\times$ Ambient Room Tone Sampling (R5) $\times$ Export (R6)**
   - *Interaction*: Cue 1 audio replaced with shorter clip (padded with room tone). Cue 2 replaced with $+5\%$ clip (time-compressed). Cue 3 unchanged. Export executed.
   - *Assertion*: Rebuilt audio track seamlessly transitions from room tone to compressed audio to original audio with 10–20ms crossfades; total exported duration matches video duration.
4. **Pair 4: Grammar Rewrite to Fit (R7) $\times$ Duration Fitting (R5)**
   - *Interaction*: Synthesized speech exceeds cue by $+15\%$ (gated overflow). User selects `[Rewrite to Fit]`. Grammar provider generates shorter text based on slot CMTime constraint. Re-synthesized speech is now $+3\%$ longer.
   - *Assertion*: System automatically time-compresses the $+3\%$ audio; clears overflow state; preserves slot boundaries.
5. **Pair 5: APFS Project Storage (R3) $\times$ Local Model Lifecycle (R8)**
   - *Interaction*: Project created on APFS volume. Heavyweight transcription and synthesis executed. Intermediate tokens and synthesized WAVs written to `.amend` bundle.
   - *Assertion*: Bundle stores all intermediate artifacts without memory residency; project reloads instantly from disk cache after process restart.
6. **Pair 6: Cloud Voice Synthesis (R5) $\times$ Keychain Security (R5/Security)**
   - *Interaction*: User synthesizes speech using ElevenLabs and Gemini cloud providers. API keys retrieved from Keychain on-demand.
   - *Assertion*: Audio synthesized successfully; project saved; `project.json` scanned and verified 100% free of plaintext keys.
7. **Pair 7: Timeline Playback Scrubbing (R1) $\times$ Local Model Coordinator Inference (R8)**
   - *Interaction*: User actively scrubs timeline and plays video/audio while PocketTTS executes local voice synthesis in background.
   - *Assertion*: Playback audio and video rendering maintain 60 fps without audio dropouts or UI thread stalling (inference isolated to background queue).

---

### Tier 4: Real-World Application Scenarios ($\ge 5$ End-to-End Scenarios)

#### Scenario 1: Developer Terminal Screen Recording Narration Replacement
* **Workflow**:
  1. Developer imports 20s recording (`terminal_demo.mov`) of a CLI build script on Apple Silicon APFS volume.
  2. Exactly 1 audio track detected; system assigns Narration track with advisory badge.
  3. FluidAudio transcribes developer's spoken explanation ("Uh, so here we run cargo build and it compiles in five seconds").
  4. Developer edits Cue 1 text to: "Here we run cargo build, completing in under five seconds."
  5. PocketTTS synthesizes voice replacement using Reference Voice. Audio is 0.8s shorter than original slot.
  6. Duration fitting pads the 0.8s with ambient room tone sampled from the developer's breathing pauses with 15ms crossfades.
  7. Developer exports final video.
* **Verification**:
  - Exported video matches source frame-for-frame, payload-for-payload.
  - Video length is identical to source.
  - Narration sounds acoustic and seamless with natural room tone.

#### Scenario 2: Hackathon Product Demo with Background Music Preservation
* **Workflow**:
  1. User imports 30s screen recording containing 2 audio tracks: Track 1 (Microphone headset), Track 2 (Desktop system audio / background music).
  2. System presents Track Picker modal; user assigns Track 1 to Narration and Track 2 to Passthrough.
  3. Narration transcribed into 6 cues.
  4. User edits Cue 3 to fix a stammered sentence.
  5. Audio synthesized and fitted via automatic compression ($+5\%$).
  6. Final export rendered.
* **Verification**:
  - Background music (Track 2) is completely untouched, retaining original audio quality and exact phase synchronization.
  - Narration track has new audio at Cue 3 without altering Cues 1, 2, 4, 5, or 6.

#### Scenario 3: Technical Code Walkthrough with Duration Overflow Gating
* **Workflow**:
  1. User records a 15s walkthrough of a Swift concurrency function.
  2. User replaces a short 2.0s cue with a detailed explanation: "This actor guarantees thread safety by isolating state mutations."
  3. Synthesized speech requires 2.70s ($+35\%$ overflow beyond the 2.0s slot).
  4. System enters Gated Overflow state: displays badge `+0.70s overflow` and offers `[Rewrite to Fit]`, `[Force Fit]`, `[Split Cue]`.
  5. User clicks `[Rewrite to Fit]`; Gemini LLM rewrites to: "Actor isolation guarantees thread safety."
  6. Re-synthesized speech requires 2.12s ($+6\%$ overflow).
  7. System automatically applies `AVAudioUnitTimePitch` compression to $2.00$s without pitch shift.
  8. Export verified.
* **Verification**:
  - Zero autonomous infinite retry loops occurred.
  - Final cue duration matches exact $2.000$s slot.
  - Code keywords preserved.

#### Scenario 4: External Drive Import with Cue Splitting and Grammar Polish
* **Workflow**:
  1. User opens a 20s recording stored on an external exFAT SSD drive.
  2. System detects `volumeSupportsFileCloning == false`; generates security-scoped bookmark in `project.json` without performing full multi-gigabyte copy.
  3. Speech transcribed. User locates a long 8.0s cue spanning two distinct screen actions.
  4. User positions playhead at $t=4.5s$ and executes `Split Cue`.
  5. Cue splits into Cue A ($[0.0s, 4.5s]$) and Cue B ($[4.5s, 8.0s]$) with zero gap.
  6. User runs "Fix Grammar" on Cue A; reviews diff modal; accepts changes.
  7. Audio re-synthesized for Cue A; fitted with room tone.
  8. Project saved and exported.
* **Verification**:
  - Zero full file copy on external drive.
  - Split operation preserved exact $t=4.5s$ boundary.
  - Invariant verified across both cues.

#### Scenario 5: Low-Memory 8GB M1 System Stress Run
* **Workflow**:
  1. Execute complete workflow on an 8GB M1 Mac mini with multiple background apps active.
  2. Import 60s multi-track recording.
  3. Execute Parakeet ASR transcription $\to$ verify ASR unloaded.
  4. Execute Grammar rewrite via local model $\to$ verify LLM unloaded.
  5. Execute 10 consecutive PocketTTS voice syntheses $\to$ verify TTS loaded only during synthesis.
  6. Render export via compressed sample passthrough pipeline.
* **Verification**:
  - Memory usage never exceeded $3.5$ GB resident RAM.
  - Zero OS memory warnings or jet-sam events triggered.
  - Video and audio fully intact.

---

## Part 4: Acceptance Criteria Verification Mapping

| AC # | Category | Acceptance Criteria Statement | Verification Method | Targeted Test Suite | Required Fixture |
|------|----------|-------------------------------|---------------------|---------------------|------------------|
| 1 | Timeline & Playback | Loads MP4/MOV recordings on macOS 14+ Apple Silicon and initializes player without transcoding. | Inspect `AVPlayerItem` asset tracks; verify no background export session is spawned; measure init latency $<200$ms. | `test_timeline_initialization_without_transcoding` | Fixture 1 |
| 2 | Timeline & Playback | Draggable playhead tracks continuous CMTime and maintains frame-accurate video seeking. | Programmatically drag playhead to non-frame CMTime; verify player presentation time matches; verify displayed frame matches calculated index. | `test_playhead_continuous_cmtime_tracking`, `test_frame_accurate_video_seeking` | Fixture 1 |
| 3 | Timeline & Playback | Internal Cue boundaries maintain exact audio-rate timestamps and are never rounded to video frames. | Assert `cue.timeRange.start` timescale equals audio timescale ($48000$ or $44100$), not video FPS ($30$). | Sync Invariant Suite, `test_cue_slot_duration_equals_cmtimerange` | Fixture 1 |
| 4 | Timeline & Playback | Waveform samples and video thumbnails scale dynamically with zoom changes (pixelsPerSecond). | Change `pixelsPerSecond` parameter from 50 to 500; assert generated waveform sample count and thumbnail count scale proportionally. | `test_waveform_dynamic_zoom_scaling`, `test_filmstrip_thumbnail_generation` | Fixture 1 |
| 5 | Audio Tracks & Storage | Single-track import presents advisory badge; multi-track import presents track assignment picker. | Load single-track asset $\to$ assert advisory badge is displayed; load multi-track asset $\to$ assert track picker modal presented. | `test_single_track_detection_advisory_badge`, `test_multi_track_detection_modal_routing` | Fixture 1 & Fixture 2 |
| 6 | Audio Tracks & Storage | Non-narration audio tracks pass through untouched to playback and export compositions. | Inspect exported audio tracks; assert Passthrough track has identical sample count, format, and SHA-256 hash. | `test_passthrough_track_retention`, Sample Payload Identity Test | Fixture 2 |
| 7 | Audio Tracks & Storage | volumeSupportsFileCloning is checked: clones via FileManager.copyItem on supported APFS volumes, falls back to security-scoped bookmarks without silent multi-gigabyte copying on foreign volumes. | Mock volume attributes with `volumeSupportsFileCloning = true` and `false`; verify file clone inode behavior vs bookmark creation. | `test_apfs_clone_detection_copyitem`, `test_bookmark_fallback_on_non_clonable_volume` | Fixture 1 |
| 8 | Audio Tracks & Storage | Project metadata accurately records source mode as cloned or externalBookmark. | Deserialize `project.json`; assert `sourceMode` property equals `"cloned"` or `"externalBookmark"`. | `test_project_metadata_source_mode` | Fixture 1 |
| 9 | Sync Invariant & Cue Operations | Modifying narration text or regenerating audio in Cue N does not change start or end of Cue N+1. | Modify text & audio of Cue $N$; assert $\text{start}(C_{N+1})_{\text{before}} == \text{start}(C_{N+1})_{\text{after}}$ and $\text{end}(C_{N+1})_{\text{before}} == \text{end}(C_{N+1})_{\text{after}}$. | Sync Invariant Suite | Fixture 1 |
| 10 | Sync Invariant & Cue Operations | Splitting a cue at t yields two valid cues spanning exactly [t_start, t] and [t, t_end] with zero gap or overlap. | Execute `splitCue(at: t)`; assert $C_A.\text{end} == C_B.\text{start} == t$, gap == 0, and combined duration equals original. | Sync Invariant Suite, `test_cue_split_zero_gap_and_overlap` | Fixture 1 |
| 11 | Sync Invariant & Cue Operations | Rendered cue duration always equals the immutable CMTimeRange of the slot. | Generate audio for cue; measure rendered audio file length via `AVAudioFile`; assert sample count equals $D_{slot} \times \text{sampleRate}$. | Sync Invariant Suite, `test_slot_duration_equals_cmtimerange` | Fixture 3 |
| 12 | Duration Fitting & Synthesis | Synthesized audio shorter than cue duration retains natural pacing and fills remainder with looped, crossfaded room tone. | Feed Clip A ($-37.5\%$); verify speech portion tempo is $1.0\times$; verify tail contains room tone; verify 10–20ms crossfade. | `test_shorter_speech_room_tone_padding`, `test_boundary_crossfade_smoothing` | Fixture 3 (Clip A) |
| 13 | Duration Fitting & Synthesis | Outputs exceeding target duration by <= 8% are automatically time-compressed to exact slot duration without pitch shift. | Feed Clip B ($+4\%$) and Clip C ($+8\%$); verify `AVAudioUnitTimePitch` invoked; verify output duration equals slot; pitch delta == 0. | `test_auto_compression_within_eight_percent`, `test_duration_fitting_at_exact_eight_percent_limit` | Fixture 3 (Clips B & C) |
| 14 | Duration Fitting & Synthesis | Outputs exceeding target duration by > 8% enter user-gated state with exact overflow time and manual action choices (Rewrite to Fit, Force Fit, Split Cue); no autonomous retry loop occurs. | Feed Clip D ($+15\%$); assert UI state == `gatedOverflow`; assert overflow value == `+0.60s`; assert retry loop counter == 0. | `test_gated_overflow_exceeding_eight_percent` | Fixture 3 (Clip D) |
| 15 | Duration Fitting & Synthesis | PocketTTS provides local voice cloning; Gemini TTS provides prebuilt natural voices without voice cloning. | Verify PocketTTS takes Reference Voice sample and generates cloned audio; verify Gemini TTS interface does not accept reference voice sample. | `test_pocket_tts_local_voice_cloning`, `test_gemini_tts_prebuilt_voices` | Fixture 3 |
| 16 | Duration Fitting & Synthesis | API keys for ElevenLabs, Resemble, and Gemini are stored exclusively in macOS Keychain. | Store keys; read back from Keychain; scan `project.json` AST for plaintext keys; assert zero leaks. | Security Suite (`test_keychain_crud`, `test_project_bundle_sanitization`) | N/A |
| 17 | Grammar & Rewriting | Grammar actions (Fix Grammar, Make Natural, Rewrite to Fit) display a text diff before applying changes. | Trigger grammar action; assert `DiffPreviewState` is presented containing original and proposed strings before state commit. | `test_grammar_provider_diff_modal_presentation` | N/A |
| 18 | Grammar & Rewriting | AI text rewrites never alter Cue start or end CMTime. | Trigger AI rewrite; commit text change; assert cue `timeRange` start and duration are bitwise identical. | Sync Invariant Suite, `test_grammar_rewrite_preserves_timing` | Fixture 1 |
| 19 | Grammar & Rewriting | Original transcript is fully recoverable after rewrites via Restore Original. | Commit AI rewrite; invoke `restoreOriginal()`; assert cue text equals initial ASR transcript. | `test_restore_original_transcript` | Fixture 1 |
| 20 | Passthrough Export | Compressed source video samples are read via AVAssetReaderTrackOutput and written via AVAssetWriterInput without decoding or re-encoding. | Verify `outputSettings: nil` configured on both reader output and writer input; assert reader produces compressed CMSampleBuffers. | Sample Payload Identity Test | Fixture 1 |
| 21 | Passthrough Export | Video codec, frame timing, frame count, dimensions, and sample payloads match source media. | Inspect exported video track; compare frame count (450), dimensions ($1920 \times 1080$), codec (`avc1`), and SHA-256 payload hashes. | Sample Payload Identity Test | Fixture 1 |
| 22 | Passthrough Export | Exported total duration matches the original video file duration. | Assert `CMTimeCompare(exportedAsset.duration, sourceAsset.duration) == 0`. | Sample Payload Identity Test | Fixture 1 |
| 23 | Model Lifecycle & Memory | LocalModelCoordinator prevents simultaneous memory residency of ASR, LLM, and PocketTTS. | Call `coordinator.load(.asr)`; call `coordinator.load(.tts)`; assert `.asr` is deallocated before `.tts` allocates. | Memory Lifecycle Test | N/A |
| 24 | Model Lifecycle & Memory | Memory footprint remains stable on 8 GB M1 systems during full transcription-to-synthesis workflows. | Execute 15-minute simulated editing workflow; assert peak resident memory $\le 3.5$ GB; assert no memory warnings. | Memory Lifecycle Test | Fixture 1 |

---

# 5-Component Handoff Report

## 1. Observation
- Inspected `/Users/fady/Dev/amend/ORIGINAL_REQUEST.md` (lines 1–138) establishing all project functional requirements R1–R8, verification resources (lines 88–98), and 24 acceptance criteria (lines 99–138).
- Inspected `/Users/fady/Dev/amend/docs/adr/0007-deterministic-avfoundation-verification-fixtures.md` mandating programmatic generation of deterministic synthetic AVFoundation fixtures (single-track, multi-track, duration fitting) and headless verification suites.
- Inspected all architectural decision records:
  - `docs/adr/0001-fixed-sync-invariant.md`: fixed-slot synchronization vs ripple editing.
  - `docs/adr/0002-native-swift-and-coreml-stack.md`: pure Swift & Core ML (FluidAudio) without Python.
  - `docs/adr/0003-ambiguity-safe-audio-track-mapping.md`: track discovery, picker modal, passthrough preservation.
  - `docs/adr/0004-apfs-clone-first-project-media-storage.md`: `FileManager.copyItem` cloning vs bookmark fallback.
  - `docs/adr/0005-ambient-room-tone-cue-padding.md`: 200–500ms VAD silence room tone sampling with 10–20ms crossfading.
  - `docs/adr/0006-user-gated-duration-overflow-handling.md`: asymmetric fitting ($\le 8\%$ auto-compression, $>8\%$ user-gated overflow).
  - `docs/adr/0008-compressed-sample-passthrough-export-pipeline.md`: `AVAssetReader` / `AVAssetWriter` compressed video passthrough with sample payload identity.
  - `docs/adr/0009-serialized-local-model-lifecycle.md`: `LocalModelCoordinator` mutual exclusion on 8GB Apple Silicon.
- Inspected `/Users/fady/Dev/amend/CONTEXT.md` defining ubiquitous language: Cue, Narration, Sync Invariant, Duration Fitting, Reference Voice, Room Tone, Passthrough Track, Project Bundle.
- Inspected workspace file tree: clean repository on branch `main` ready for Milestone 0 verification scaffolding.

## 2. Logic Chain
1. *From ORIGINAL_REQUEST.md and ADR 0007*: Programmatic AVFoundation fixtures are strictly required because manual testing or static analysis cannot verify millisecond-accurate sync invariants, bitstream payload preservation, or audio crossfades.
2. *From Fixture 1 specification*: Generating a 15-second synthetic video with burned-in SMPTE timecode (450 frames @ 30fps) and a single audio track with 440Hz/880Hz tone bursts separated by 1-second silence regions creates a known ground truth for frame-accurate seeking, waveform rendering, cue segmentation, and passthrough export.
3. *From Fixture 2 specification*: Adding a secondary audio track with continuous background noise enables testing ambiguity-safe track detection, picker routing, and bit-for-bit passthrough muxing without touching the secondary track.
4. *From Fixture 3 specification*: Testing speech duration deltas of $-37.5\%$, $+4\%$, $+8\%$, and $+15\%$ against a 4.000s slot objectively verifies room tone padding, 10–20ms crossfades, automatic compression thresholds, and strict manual overflow gating.
5. *From Sync Invariant specification*: Enforcing that $\forall k \ne N$, Cue $k$ boundaries remain identical when Cue $N$ is mutated guarantees that video timing is never altered by narration changes.
6. *From Sample Payload Identity specification*: Extracting CMSampleBuffers before and after export and comparing presentation timestamps and SHA-256 block buffer checksums proves that video samples are passed through without re-encoding.
7. *From Memory Lifecycle specification*: Enforcing that `LocalModelCoordinator` serializes ASR, LLM, and TTS inference ensures the application operates reliably within an 8 GB Apple Silicon memory ceiling without triggering system memory pressure.
8. *From Security Suite specification*: Testing Keychain `kSecClassGenericPassword` round-trips and scanning `project.json` ensures API keys never leak into project files.
9. *From E2E 4-Tier Framework*: Requiring $\ge 5$ feature tests and $\ge 5$ boundary tests per feature (R1–R8), along with pairwise and real-world scenarios, guarantees comprehensive test coverage across all architectural requirements.

## 3. Caveats
- No source code or tests exist yet in the workspace; this report defines the authoritative specification and parameters that subsequent implementation agents must build against.
- Video container format should support both MP4 (`avc1`) and MOV (`hvc1`/`avc1`) to ensure compatibility across macOS versions.
- Floating-point arithmetic must never be used for `CMTime` boundary comparisons; rational time arithmetic is mandatory.

## 4. Conclusion
The verification specifications, synthetic AVFoundation fixture parameters, required test suites, 4-tier E2E testing framework, and acceptance criteria mappings are fully mined, cataloged, and mathematically specified. The testing framework guarantees zero-drift synchronization, bitstream passthrough preservation, memory safety on 8GB hardware, and credential security.

## 5. Verification Method
1. Inspect `/Users/fady/Dev/amend/.agents/spec_miner_fixtures_0/handoff.md` to review the complete specification report.
2. Verify all 3 synthetic fixtures, 4 test suites, 4 E2E tiers, and 24 acceptance criteria are completely accounted for without omissions.
3. When the implementation agent scaffolds the test suite in `Tests/`, run:
   ```bash
   swift test
   ```
   and assert that all suites (Sync Invariant, Sample Payload Identity, Memory Lifecycle, Security, and E2E Tiers) execute and pass.
