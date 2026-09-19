# Original User Request

## Initial Request — 2026-09-16T12:37:28Z

# Teamwork Project Prompt

A native macOS application (Amend) for developer and hackathon screen recordings that enables transcript-based speech editing, narration replacement, and voice cloning while strictly preserving an immutable video timeline with zero synchronization drift.

Deployment Target: macOS 14.0+, Apple Silicon (arm64)
Working directory: /Users/fady/Dev/amend
Integrity mode: development

## Architecture & Design References
- Domain Glossary: CONTEXT.md
- Architectural Decisions:
  - docs/adr/0001-fixed-sync-invariant.md: Fixed-slot synchronization vs ripple editing
  - docs/adr/0002-native-swift-and-coreml-stack.md: Pure native Swift & Core ML (FluidAudio) without Python
  - docs/adr/0003-ambiguity-safe-audio-track-mapping.md: Ambiguity-safe audio track selection & passthrough preservation
  - docs/adr/0004-apfs-clone-first-project-media-storage.md: APFS copy-on-write cloning via FileManager.copyItem with bookmark fallback
  - docs/adr/0005-ambient-room-tone-cue-padding.md: Ambient room-tone sampling and boundary crossfade padding
  - docs/adr/0006-user-gated-duration-overflow-handling.md: Asymmetric duration fitting with strict user manual gating on overflow
  - docs/adr/0007-deterministic-avfoundation-verification-fixtures.md: Deterministic synthetic AVFoundation verification fixtures
  - docs/adr/0008-compressed-sample-passthrough-export-pipeline.md: Compressed-sample passthrough export pipeline via AVAssetReader / AVAssetWriter
  - docs/adr/0009-serialized-local-model-lifecycle.md: Serialized local model lifecycle for 8GB Apple Silicon

## Requirements

### R1. Native Video Playback & Pro Synchronized Timeline
Build a native macOS video viewer and horizontal timeline driven strictly by CMTime and CMTimeRange with synchronized visual layers:
- SMPTE timecode ruler using SwiftTimecode for drop-frame/standard frame rate handling.
- Video thumbnail filmstrip rendered asynchronously using AVAssetImageGenerator.
- Audio waveform track extracting normalized sample buffers using DSWaveformImage analyzer.
- Narration cue track displaying time-locked slots with text, duration, and edit state badges.
- Horizontal zoom controlled by pixelsPerSecond with a continuous CMTime-based draggable playhead providing frame-accurate video seeking and audio-resolution Cue boundary representation.
- Maintain a strict distinction between timelineTime (high-resolution CMTime) and displayTimecode (frame-quantized SMPTE representation). Never round internal Cue boundaries to video frames.

### R2. Fixed-Slot Audio Invariant & Composition Engine
Implement an audio composition engine where video timestamps belong exclusively to the video and never move when narration is altered:
- Every Cue maintains immutable start and end CMTime boundaries.
- Editing narration text or replacing audio in Cue N guarantees Cue[N+1].start and Cue[N+1].end remain identical.
- Splitting a cue at playhead t produces [t_start, t] and [t, t_end] with zero gap or overlap.
- Audio replacements apply loudness normalization and 10–20 ms boundary crossfades.

### R3. Ambiguity-Safe Audio Track Import & Project Storage
Implement media import and project bundle packaging:
- Automatically inspect all audio tracks in source media. If exactly 1 audio track is found, assign it as Narration with a single-track advisory badge. If >1 audio tracks are found, prompt the user with a Track Picker modal to designate Narration vs Passthrough tracks.
- When creating a .amend Project Bundle, inspect the destination volume's volumeSupportsFileCloning. If cloning is supported and source/destination permit cloning, copy the source media into Project.amend/source.<ext> using FileManager.copyItem (APFS copy-on-write). If cloning is not supported, do NOT perform a full multi-gigabyte copy; instead store a security-scoped bookmark to the original file.
- Record in project.json whether the source is cloned or externalBookmark. Store project metadata, cached waveform data, thumbnail caches, and synthesized cue WAVs in the bundle. Never store plain text API keys in the bundle.

### R4. Word-Aligned Transcription & Cue Generation
Integrate FluidAudio (Parakeet Core ML ASR and Silero VAD) to generate word-timestamped narration cues from the designated Narration track. Clicking a cue seeks video playback; playback actively highlights the active cue.

### R5. Asymmetric Duration Fitting & Voice Synthesis
Implement voice synthesis via local PocketTTS voice cloning, cloud cloned-voice providers ElevenLabs and Resemble, and Gemini TTS as an optional natural prebuilt-voice provider (Gemini must NOT be implemented or described as cloning the user's Reference Voice). Generated audio is fitted into fixed cue slots using an asymmetric duration model:
- Shorter speech: Retain natural speaking rate; fill residual slot duration with ambient room tone (sampled from 200–500ms VAD silence) with 10–20ms crossfading.
- Speech exceeding duration by <= 8%: Automatically time-compress using AVAudioUnitTimePitch offline rendering, preserving original vocal pitch.
- Speech exceeding duration by > 8%: Gated manual overflow state displaying exact overflow (e.g. +1.42s) and offering [Rewrite to Fit], [Force Fit], and [Split Cue]. No uncontrolled automated retry loops.

### R6. Compressed-Sample Passthrough Export Pipeline
Implement a deterministic video export pipeline using AVAssetReader and AVAssetWriter:
- Configure AVAssetReaderTrackOutput(outputSettings: nil) for the source video track so compressed video samples are read without decoding.
- Configure AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: ...) to write those compressed video samples without re-encoding.
- Preserve all Passthrough Tracks in their stored format where container compatibility permits.
- Render modified Narration audio separately and encode only the rebuilt audio track when required by the destination container.
- Mux all resulting tracks while strictly preserving video sample presentation timestamps.
- Use AVAssetExportSession with AVAssetExportPresetPassthrough only as an optional fast-path shortcut when compatibility has been positively verified, retaining the reader/writer pipeline as the deterministic standard.

### R7. Grammar Correction & Duration-Aware Script Rewriting
Provide transcript editing actions:
- Fix Grammar
- Make Natural
- Rewrite to Fit
- Restore Original
Text rewriting must preserve developer terminology, product names, code identifiers, URLs, numbers, and intended factual meaning.
- Providers: Local Apple Foundation Models (when running on supported newer OS versions) and cloud Gemini API, behind a pluggable GrammarProvider protocol.
- For Rewrite to Fit, pass the immutable Cue duration and estimated speaking-length constraint to the model.
- All AI rewrites must display a text diff modal/popover before replacing user-authored Narration. Rewriting text must never modify Cue timing.
- Original transcripts must remain recoverable after every AI rewrite. Failure or absence of an LLM provider must not block manual editing or voice synthesis.

### R8. Local Model Lifecycle for 8GB Apple Silicon
Coordinate all local AI models through a centralized LocalModelCoordinator:
- Enforce strict lifecycle separation: do not keep ASR, local LLM, and PocketTTS resident in memory simultaneously.
- Release ASR resources after initial transcription before loading PocketTTS.
- Serialize heavyweight local inference jobs to prevent memory pressure and swapping.
- Cache transcription tokens and synthesized audio WAVs to disk so model weights do not need to remain resident.
- Gracefully handle model loading/download failures without corrupting project state.

## Verification Resources & Test Harness

Implement automated programmatic test suites in Tests/ using synthetic AVFoundation fixtures:
1. Fixture 1 (Single-track): Deterministic 10–20s synthetic video with embedded timecode frames, single audio track with tone bursts and silence regions. Tests loading, waveform extraction, cue splitting, and export duration.
2. Fixture 2 (Multi-track): Synthetic video with Track 1 (narration tone) and Track 2 (background noise). Tests track picker routing, background track preservation, and independent passthrough muxing.
3. Fixture 3 (Duration Fitting): Test replacement audio at shorter, +4%, +8%, and +15% durations. Verifies room-tone padding, automatic compression, and +15% overflow gating.
4. Sync Invariant Suite: Asserts Cue[N+1].startBefore == Cue[N+1].startAfter across text edits, splits, and re-renders.
5. Sample Payload Identity Test: Verifies that compressed video samples in exported files match source video sample payloads and timestamps without alteration.
6. Memory Lifecycle Test: Instrumentation test verifying transcription followed by local voice generation completes within an 8 GB M1 RAM budget without triggering memory warnings.
7. Security Suite: Asserts cloud API keys round-trip through macOS Keychain (kSecClassGenericPassword) and project.json contains no plaintext credentials.

## Acceptance Criteria

### Timeline & Playback
- [ ] Loads MP4/MOV recordings on macOS 14+ Apple Silicon and initializes player without transcoding.
- [ ] Draggable playhead tracks continuous CMTime and maintains frame-accurate video seeking.
- [ ] Internal Cue boundaries maintain exact audio-rate timestamps and are never rounded to video frames.
- [ ] Waveform samples and video thumbnails scale dynamically with zoom changes (pixelsPerSecond).

### Audio Tracks & Storage
- [ ] Single-track import presents advisory badge; multi-track import presents track assignment picker.
- [ ] Non-narration audio tracks pass through untouched to playback and export compositions.
- [ ] volumeSupportsFileCloning is checked: clones via FileManager.copyItem on supported APFS volumes, falls back to security-scoped bookmarks without silent multi-gigabyte copying on foreign volumes.
- [ ] Project metadata accurately records source mode as cloned or externalBookmark.

### Sync Invariant & Cue Operations
- [ ] Modifying narration text or regenerating audio in Cue N does not change start or end of Cue N+1.
- [ ] Splitting a cue at t yields two valid cues spanning exactly [t_start, t] and [t, t_end] with zero gap or overlap.
- [ ] Rendered cue duration always equals the immutable CMTimeRange of the slot.

### Duration Fitting & Synthesis
- [ ] Synthesized audio shorter than cue duration retains natural pacing and fills remainder with looped, crossfaded room tone.
- [ ] Outputs exceeding target duration by <= 8% are automatically time-compressed to exact slot duration without pitch shift.
- [ ] Outputs exceeding target duration by > 8% enter user-gated state with exact overflow time and manual action choices (Rewrite to Fit, Force Fit, Split Cue); no autonomous retry loop occurs.
- [ ] PocketTTS provides local voice cloning; Gemini TTS provides prebuilt natural voices without voice cloning.
- [ ] API keys for ElevenLabs, Resemble, and Gemini are stored exclusively in macOS Keychain.

### Grammar & Rewriting
- [ ] Grammar actions (Fix Grammar, Make Natural, Rewrite to Fit) display a text diff before applying changes.
- [ ] AI text rewrites never alter Cue start or end CMTime.
- [ ] Original transcript is fully recoverable after rewrites via Restore Original.

### Passthrough Export
- [ ] Compressed source video samples are read via AVAssetReaderTrackOutput and written via AVAssetWriterInput without decoding or re-encoding.
- [ ] Video codec, frame timing, frame count, dimensions, and sample payloads match source media.
- [ ] Exported total duration matches the original video file duration.

### Model Lifecycle & Memory
- [ ] LocalModelCoordinator prevents simultaneous memory residency of ASR, LLM, and PocketTTS.
- [ ] Memory footprint remains stable on 8 GB M1 systems during full transcription-to-synthesis workflows.
