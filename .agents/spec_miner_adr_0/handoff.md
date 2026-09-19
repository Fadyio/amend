# Architectural Specification & Domain Invariants Report

**Author**: Architecture & ADR Spec Miner (`spec_miner_adr_0`)  
**Target Repository**: `/Users/fady/Dev/amend`  
**Deployment Target**: macOS 14.0+, Apple Silicon (`arm64`), 8GB RAM minimum base  
**Specification Sources**:
- `ORIGINAL_REQUEST.md`
- `CONTEXT.md`
- `docs/adr/0001-fixed-sync-invariant.md` through `docs/adr/0009-serialized-local-model-lifecycle.md`

---

## 1. Observation

Direct observations extracted from the authoritative repository specification files:

### 1.1 Fixed-Slot Synchronization & Invariant Definition
- **CONTEXT.md (Lines 7–18)**:
  > "**Cue**: A fixed time-slot in the video containing narration, bounded by immutable start and end timestamps in video time. _Avoid_: Clip, segment, chunk, region, subtitle"  
  > "**Narration**: The spoken vocal audio corresponding to the video, which can be transcribed, edited, or re-synthesized. _Avoid_: Speech, voiceover, dialogue, audio track"  
  > "**Sync Invariant**: The architectural guarantee that cue time boundaries are strictly locked to the video timeline and never shift when narration text or audio changes. _Avoid_: Fixed sync, time lock, time constraint"
- **ADR 0001 (Lines 1–4)**:
  > "Traditional audio/video transcript editors (such as Descript) ripple-edit the timeline when text is added or removed, which alters video length and breaks screen action synchronization. We decided that video timestamps are strictly immutable (`CMTime` / `CMTimeRange`), meaning cues never shift when narration is edited. Generated audio must always be fitted to the slot (via padding, time-stretching, or rewriting) to preserve exact video alignment and allow instant passthrough mux export."
- **ORIGINAL_REQUEST.md (Lines 37–43)**:
  > "Every Cue maintains immutable start and end CMTime boundaries."  
  > "Editing narration text or replacing audio in Cue N guarantees Cue[N+1].start and Cue[N+1].end remain identical."  
  > "Splitting a cue at playhead t produces [t_start, t] and [t, t_end] with zero gap or overlap."  
  > "Audio replacements apply loudness normalization and 10–20 ms boundary crossfades."

### 1.2 Timeline Representation & Visual Layers
- **ORIGINAL_REQUEST.md (Lines 28–36)**:
  > "Maintain a strict distinction between timelineTime (high-resolution CMTime) and displayTimecode (frame-quantized SMPTE representation). Never round internal Cue boundaries to video frames."  
  > "SMPTE timecode ruler using SwiftTimecode for drop-frame/standard frame rate handling."  
  > "Video thumbnail filmstrip rendered asynchronously using AVAssetImageGenerator."  
  > "Audio waveform track extracting normalized sample buffers using DSWaveformImage analyzer."  
  > "Narration cue track displaying time-locked slots with text, duration, and edit state badges."  
  > "Horizontal zoom controlled by pixelsPerSecond with a continuous CMTime-based draggable playhead providing frame-accurate video seeking and audio-resolution Cue boundary representation."

### 1.3 Native Swift & Core ML Stack Without Python
- **ADR 0002 (Lines 1–4)**:
  > "Running local ML models in desktop apps often relies on embedded Python runtimes or localhost HTTP microservices, which introduce complex installation, process management, and resource overhead. We decided to build purely native Swift using Core ML and the `FluidAudio` package for local ASR, VAD, and PocketTTS voice cloning, combined with native AVFoundation audio units for processing. This keeps the application bundle lean, minimizes background overhead on 8GB Apple Silicon Macs, and eliminates all Python or FFmpeg dependencies."
- **ORIGINAL_REQUEST.md (Lines 50–52, 80–87)**:
  > "Integrate FluidAudio (Parakeet Core ML ASR and Silero VAD) to generate word-timestamped narration cues from the designated Narration track."  
  > "Enforce strict lifecycle separation: do not keep ASR, local LLM, and PocketTTS resident in memory simultaneously."  
  > "Release ASR resources after initial transcription before loading PocketTTS."  
  > "Serialize heavyweight local inference jobs to prevent memory pressure and swapping."

### 1.4 Ambiguity-Safe Audio Track Mapping
- **ADR 0003 (Lines 1–4)**:
  > "Screen and demo recordings vary widely, containing either a single mixed audio track or separate microphone and desktop audio tracks. We decided to inspect all audio tracks on import: if exactly one audio track exists, it is automatically assigned as Narration with a single-track warning; if multiple tracks exist, a lightweight Track Picker modal prompts the user to confirm the Narration track and Passthrough tracks. This avoids assuming Track 1 is always the microphone, prevents unintentional erasure of desktop system audio, and preserves unedited tracks untouched throughout playback and export."
- **CONTEXT.md (Lines 31–34)**:
  > "**Passthrough Track**: An audio track from the source recording that is passed through untouched without editing or re-encoding. _Avoid_: Secondary track, unedited track, system track (when referring to passthrough behavior)"

### 1.5 APFS Clone-First Media Storage & Project Bundles
- **ADR 0004 (Lines 1–4)**:
  > "Referencing source media by path risks broken projects when files are renamed or deleted, while naive full copying wastes gigabytes of disk space and slows down project creation. We decided to create self-contained Project Bundles (`.amend`) using `FileManager.copyItem`, which leverages APFS copy-on-write cloning when source and destination are on the same APFS volume to achieve instant, zero-additional-disk-space duplicates. When cloning is unsupported (such as cross-volume or non-APFS drives), the bundle falls back gracefully to a security-scoped bookmark."
- **ORIGINAL_REQUEST.md (Lines 46–49)**:
  > "When creating a .amend Project Bundle, inspect the destination volume's volumeSupportsFileCloning. If cloning is supported and source/destination permit cloning, copy the source media into Project.amend/source.<ext> using FileManager.copyItem (APFS copy-on-write). If cloning is not supported, do NOT perform a full multi-gigabyte copy; instead store a security-scoped bookmark to the original file."  
  > "Record in project.json whether the source is cloned or externalBookmark. Store project metadata, cached waveform data, thumbnail caches, and synthesized cue WAVs in the bundle. Never store plain text API keys in the bundle."

### 1.6 Ambient Room-Tone Cue Padding
- **ADR 0005 (Lines 1–4)**:
  > "Replacing spoken narration with shorter synthesized audio and padding the remaining duration with raw digital silence creates an unnatural acoustic drop on headphones. We decided to sample a 200–500 ms ambient silence slice from the source Narration track (identified via Silero VAD) to serve as project-level room tone. When synthesized speech is shorter than the target Cue duration, the audio starts at natural speed at the Cue boundary, the remaining duration is filled with looped, crossfaded room tone, and 10–20 ms boundary crossfades are applied to guarantee seamless acoustic continuity and exact `CMTimeRange` adherence."
- **CONTEXT.md (Lines 27–30)**:
  > "**Room Tone**: A sampled slice of ambient background sound from the source Narration track used to fill residual gaps in Cues. _Avoid_: Silence padding, background noise, atmosphere"

### 1.7 Asymmetric Duration Fitting & Manual Overflow Gating
- **ADR 0006 (Lines 1–4)**:
  > "Automatic LLM rewrite and re-synthesis loops can waste API credits, consume high CPU/memory on 8GB Apple Silicon hardware, and alter text the user intended to preserve. We decided on an asymmetric duration fitting policy: shorter audio preserves natural speech with room-tone padding, audio exceeding cue duration by ≤8% is automatically time-compressed via `AVAudioUnitTimePitch` without pitch shift, and audio exceeding duration by >8% enters a strict user-gated state presenting exact overflow time and three explicit actions (`Rewrite to Fit`, `Force Fit`, `Split Cue`). Uncontrolled automatic retry loops are strictly forbidden."
- **ORIGINAL_REQUEST.md (Lines 53–58)**:
  > "Speech exceeding duration by <= 8%: Automatically time-compress using AVAudioUnitTimePitch offline rendering, preserving original vocal pitch."  
  > "Speech exceeding duration by > 8%: Gated manual overflow state displaying exact overflow (e.g. +1.42s) and offering [Rewrite to Fit], [Force Fit], and [Split Cue]. No uncontrolled automated retry loops."  
  > "Gemini must NOT be implemented or described as cloning the user's Reference Voice."

### 1.8 Compressed-Sample Passthrough Export Pipeline
- **ADR 0008 (Lines 1–4)**:
  > "Relying solely on `AVAssetExportPresetPassthrough` provides no API guarantees against silent re-encoding and cannot guarantee bitstream sample identity across all container types. We decided to implement an explicit remuxing pipeline using `AVAssetReaderTrackOutput(outputSettings: nil)` and `AVAssetWriterInput(outputSettings: nil)` to read and write compressed video samples without decoding. Only modified Narration audio is rendered and encoded, while video samples and Passthrough Tracks retain their exact original compression, frame timing, and payload hashes."
- **ORIGINAL_REQUEST.md (Lines 59–67)**:
  > "Configure AVAssetReaderTrackOutput(outputSettings: nil) for the source video track so compressed video samples are read without decoding."  
  > "Configure AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: ...) to write those compressed video samples without re-encoding."  
  > "Preserve all Passthrough Tracks in their stored format where container compatibility permits."  
  > "Render modified Narration audio separately and encode only the rebuilt audio track when required by the destination container."  
  > "Mux all resulting tracks while strictly preserving video sample presentation timestamps."  
  > "Use AVAssetExportSession with AVAssetExportPresetPassthrough only as an optional fast-path shortcut when compatibility has been positively verified, retaining the reader/writer pipeline as the deterministic standard."

### 1.9 Grammar Correction & Script Rewriting
- **ORIGINAL_REQUEST.md (Lines 68–79)**:
  > "Provide transcript editing actions: Fix Grammar, Make Natural, Rewrite to Fit, Restore Original."  
  > "Text rewriting must preserve developer terminology, product names, code identifiers, URLs, numbers, and intended factual meaning."  
  > "Providers: Local Apple Foundation Models (when running on supported newer OS versions) and cloud Gemini API, behind a pluggable GrammarProvider protocol."  
  > "For Rewrite to Fit, pass the immutable Cue duration and estimated speaking-length constraint to the model."  
  > "All AI rewrites must display a text diff modal/popover before replacing user-authored Narration. Rewriting text must never modify Cue timing."  
  > "Original transcripts must remain recoverable after every AI rewrite. Failure or absence of an LLM provider must not block manual editing or voice synthesis."

### 1.10 Serialized Local Model Lifecycle for 8GB Apple Silicon
- **ADR 0009 (Lines 1–4)**:
  > "Running Core ML ASR (Parakeet), speech synthesis (PocketTTS), and local LLMs simultaneously quickly exhausts memory and causes swapping on 8GB Apple Silicon Macs. We decided to coordinate all local models through a singleton `LocalModelCoordinator` that enforces mutual exclusion: ASR resources are released after initial transcription before PocketTTS is loaded, heavyweight inference jobs are strictly serialized, and intermediate results are cached to disk so weights do not remain resident."
- **ORIGINAL_REQUEST.md (Lines 80–87)**:
  > "Coordinate all local AI models through a centralized LocalModelCoordinator."  
  > "Cache transcription tokens and synthesized audio WAVs to disk so model weights do not need to remain resident."  
  > "Gracefully handle model loading/download failures without corrupting project state."

---

## 2. Logic Chain

From these direct observations, we derive the structural architecture and invariant constraints:

### Step 2.1: The Invariant Foundation (R1 & R2)
1. **Observation**: ADR 0001 and R2 state that cues never ripple and video timestamps belong exclusively to the video (`CMTimeRange`).
2. **Inference**: Traditional NLE or subtitle models treat subtitles as transient overlays or rippling clips. Amend's core data structure must be a fixed contiguous or disjoint set of immutable slots.
3. **Deduction**:
   - `Cue` boundary coordinates `[start, end]` are keyed to video timeline time `CMTime`.
   - Any operation on `Cue[N]` (replacing audio, rewriting text, silence filling) is constrained within `[Cue[N].start, Cue[N].end]`.
   - The assertion `Cue[N+1].startBefore == Cue[N+1].startAfter` must hold across all operations.
   - Cue splitting at time $t$ where $t \in (\text{start}, \text{end})$ splits the time slot into $[\text{start}, t]$ and $[t, \text{end}]$. Since $\lim_{\epsilon \to 0} [(\text{start}, t) \cup (t, \text{end})] = [\text{start}, \text{end}]$, there is exactly zero gap and zero overlap.
   - Timeline time (`CMTime`) must use audio-sample or sub-millisecond timescale (e.g. timescale 48,000 or 60,000) and must NEVER be truncated or rounded to video frame boundaries (e.g. 1/30s or 1/60s). `SwiftTimecode` is strictly for display/ruler rendering.

### Step 2.2: Native Apple Silicon Runtime & Zero-Python Constraint (ADR 0002 & R8)
1. **Observation**: ADR 0002 mandates pure native Swift using Core ML and `FluidAudio` without Python, FFmpeg, or microservices.
2. **Inference**: Any dependency requiring `python3`, `pip`, PyTorch, or embedded subprocesses is strictly prohibited.
3. **Deduction**:
   - ASR must be executed via `FluidAudio` using Core ML Parakeet models.
   - VAD must run via Core ML Silero VAD in `FluidAudio`.
   - Local voice cloning must run via PocketTTS compiled to Core ML / Swift.
   - Audio manipulation (resampling, pitch-preserving time stretching, mixing, crossfading) must use native macOS frameworks: `AVFoundation`, `AVAudioEngine`, `AVAudioUnitTimePitch`, and `Accelerate` (vDSP).

### Step 2.3: Storage Lifecycle & Project Packaging (ADR 0004 & R3)
1. **Observation**: Source media files can be tens of gigabytes. Naive copying consumes storage and time; path referencing causes dangling pointers when users move files.
2. **Inference**: APFS provides file cloning via `FileManager.copyItem`, which creates copy-on-write extents in milliseconds. But external drives or non-APFS volumes do not support cloning.
3. **Deduction**:
   - The app must query destination volume attributes (`URLResourceValues.volumeSupportsFileCloning`).
   - If cloning is supported on the target volume and media is local to that volume, clone source into `.amend/source.<ext>`.
   - If cloning is unsupported (cross-volume or non-APFS), store a `security-scoped bookmark` to avoid copying large files.
   - `project.json` stores an explicit enum: `sourceStorageMode = .cloned(relativePath: "source.mp4")` or `.externalBookmark(bookmarkData: Data, originalPath: String)`.
   - API keys for cloud services must NEVER be written to `project.json`; they must be stored in the macOS Keychain (`kSecClassGenericPassword`).

### Step 2.4: Ambiguity-Safe Audio Routing (ADR 0003)
1. **Observation**: Screen recordings often contain multiple tracks (mic, system audio, game audio), or a single mixed track.
2. **Inference**: Automatic assignment of Track 1 to microphone can silently discard or overwrite system audio.
3. **Deduction**:
   - When audio track count $C == 1$: automatically assign to Narration and display an advisory badge informing the user that background and voice cannot be unmixed.
   - When audio track count $C > 1$: present an interactive `Track Picker` modal forcing explicit user selection of the single Narration track, marking all remaining tracks as Passthrough Tracks.
   - Passthrough tracks are preserved without decoding, modification, or re-encoding during playback composition and export.

### Step 2.5: Acoustic Continuity & Room-Tone Padding (ADR 0005)
1. **Observation**: When synthesized audio is shorter than the cue slot, digital silence (zeros) creates an acoustic vacuum that sounds unnatural on headphones.
2. **Inference**: Natural recordings contain room reflections, HVAC hum, fan noise, and preamp floor (Room Tone).
3. **Deduction**:
   - On import/transcription, Silero VAD detects non-speech segments in the designated Narration track.
   - The engine extracts a 200–500 ms slice of ambient silence as the project-level Room Tone asset (`room_tone.wav`).
   - For shorter speech, the synthesized audio plays from $t_{\text{start}}$, and the remainder $[t_{\text{synth\_end}}, t_{\text{end}}]$ is filled with seamlessly looped Room Tone.
   - A 10–20 ms equal-power or linear crossfade is applied between speech and room tone, and across cue boundaries.

### Step 2.6: Asymmetric Duration Fitting & Manual Gating (ADR 0006 & R5)
1. **Observation**: Unconstrained automatic LLM retries or extreme time stretching produce degraded audio and high API/CPU consumption.
2. **Inference**: Small duration excesses (up to 8%) can be imperceptibly compressed by `AVAudioUnitTimePitch` without pitch shifting. Larger excesses require human editorial decisions.
3. **Deduction**:
   - Fitting policy is strictly asymmetric:
     - $\Delta \le 0$ (shorter): 100% natural speech rate + room tone padding + 10–20ms crossfade.
     - $0 < \Delta \le +8\%$: automatic offline `AVAudioUnitTimePitch` compression to exact slot duration (rate $\in [1.00, 1.08]$).
     - $\Delta > +8\%$: Gated Manual Overflow state. The UI displays the exact overflow amount in seconds (e.g. `+1.42s`) and presents three explicit choices: `[Rewrite to Fit]`, `[Force Fit]`, `[Split Cue]`.
     - Autonomous re-generation loops are strictly forbidden.

### Step 2.7: Compressed-Sample Passthrough Export (ADR 0008 & R6)
1. **Observation**: Transcoding video during export causes generation loss, takes minutes, and changes timestamps. `AVAssetExportPresetPassthrough` lacks granular track-level control and failure guarantees.
2. **Inference**: Video compressed frames (`CMSampleBuffer`) can be piped directly from `AVAssetReaderTrackOutput(outputSettings: nil)` to `AVAssetWriterInput(outputSettings: nil)`.
3. **Deduction**:
   - Video track: Raw compressed sample buffers are read and written with identical presentation timestamps (`PTS`), decode timestamps (`DTS`), and dimensions.
   - Passthrough audio tracks: Copied without re-encoding where container compatibility permits.
   - Narration audio track: Rendered from cue timeline (synthesized audio + unedited source audio + room tone padding + boundary crossfades), and encoded to target audio format (e.g., AAC or Linear PCM).
   - Exported container duration matches source video file duration exactly.

### Step 2.8: Memory Coordination for 8GB Unified Memory (ADR 0009 & R8)
1. **Observation**: Base Apple Silicon Macs share 8GB unified memory between CPU, GPU, Neural Engine (ANE), and macOS system frameworks. Parakeet Core ML ASR (~1.5–2GB), PocketTTS (~1.5–2GB), and local LLMs (~2–3GB) resident together cause severe memory pressure, swapping, and jetsam terminations.
2. **Inference**: Models are only needed during their respective pipeline steps.
3. **Deduction**:
   - Implement `LocalModelCoordinator` as an actor/singleton enforcing mutually exclusive memory residency.
   - Workflow sequence:
     1. Load VAD & Parakeet ASR. Run transcription. Cache word tokens and cues to disk.
     2. Unload Parakeet ASR and release Core ML model instances.
     3. Load PocketTTS only when voice cloning/synthesis is requested. Perform synthesis. Cache WAV to disk.
     4. Unload PocketTTS when idle.
   - Because all intermediates (tokens, waveforms, audio WAVs) are cached to disk, timeline playback and editing operate with zero model memory footprint.

---

## 3. Features Discovered

| # | Category | Feature | Description | Inputs | Outputs | Error Behavior | Discovered Via |
|---|----------|---------|-------------|--------|---------|----------------|----------------|
| 1 | Timeline | CMTime Master Clock | High-resolution timeline tracking audio-rate boundaries without frame quantization | Playhead seek `CMTime`, zoom level `pixelsPerSecond` | Current `CMTime`, active Cue highlight | Clamps to `[0, totalDuration]` | R1, ADR 0001 |
| 2 | Timeline | SMPTE Timecode Ruler | Frame-rate aware timecode display supporting standard and drop-frame rates | Video frame rate (fps), current `CMTime` | Formatted SMPTE string (HH:MM:SS:FF / HH:MM:SS;FF) | Falls back to non-drop-frame if rate unsupported | R1, SwiftTimecode |
| 3 | Timeline | Async Video Filmstrip | Asynchronously generated thumbnail strip scaled by `pixelsPerSecond` | Timeline width, zoom, video track | Cached thumbnail images rendered along ruler | Displays placeholder image on generation failure | R1, AVAssetImageGenerator |
| 4 | Timeline | Waveform Display | Extraction of normalized audio sample buffers for Narration track | Narration audio track, zoom factor | Normalized waveform peak buffers | Empty waveform if track is silent/corrupted | R1, DSWaveformImage |
| 5 | Timeline | Draggable Playhead | Real-time continuous scrubbing with frame-accurate video update | Drag gesture offset / mouse position | Updated player `CMTime`, synchronized video frame | Clamped to project bounds | R1 |
| 6 | Sync Engine | Fixed-Slot Invariant | Guaranteed immutability of Cue boundaries across text and audio edits | Cue modification request, replacement audio | Immutable `CMTimeRange` preserved; adjacent cues untouched | Throws invariant violation error if boundary shifts | R2, ADR 0001 |
| 7 | Sync Engine | Cue Splitting | Split Cue at playhead $t$ into two contiguous cues $[t_{\text{start}}, t]$ and $[t, t_{\text{end}}]$ | Target Cue, split timestamp $t$ | Two new Cues with zero gap and zero overlap | Rejects split if $t \le t_{\text{start}}$ or $t \ge t_{\text{end}}$ | R2 |
| 8 | Sync Engine | Boundary Crossfader | Applies 10–20 ms linear/equal-power crossfade at cue start/end boundaries | Replacement audio buffer, adjacent audio buffer | Crossfaded audio sample buffer | Falls back to abrupt cut if buffer shorter than crossfade window | R2, ADR 0005 |
| 9 | Sync Engine | Loudness Normalizer | Normalizes replacement audio to match target narration LUFS/RMS levels | Synthesized audio buffer, reference loudness | Normalized audio buffer | Clamps gain adjustment to prevent clipping | R2 |
| 10 | Media Import | Audio Track Inspector | Enumerates audio tracks in source container and determines routing | `AVAsset` audio tracks | Audio track metadata list (channel count, format, language) | Fails import if 0 audio tracks found | R3, ADR 0003 |
| 11 | Media Import | Single-Track Warning | Automatically routes single track to Narration and shows advisory badge | Source with 1 audio track | Assigned Narration track + UI advisory badge | None (automatic path) | R3, ADR 0003 |
| 12 | Media Import | Multi-Track Track Picker | Interactive modal to designate Narration track vs Passthrough tracks | Source with $>1$ audio tracks, user selection | Designated Narration track ID, Passthrough track IDs | Blocks progression until exactly 1 Narration track is selected | R3, ADR 0003 |
| 13 | Storage | APFS File Cloner | Copy-on-write cloning of source video via `FileManager.copyItem` | Source file URL, destination bundle URL | Cloned video file at `.amend/source.<ext>` | Falls back to security-scoped bookmark if cloning fails | R3, ADR 0004 |
| 14 | Storage | Security-Scoped Bookmark Fallback | Non-copying bookmark reference for cross-volume / non-APFS storage | Source file URL outside APFS volume | Serialized security-scoped bookmark in `project.json` | Displays missing media dialog if external file moved/deleted | R3, ADR 0004 |
| 15 | Storage | Project Bundle Serializer | Encapsulates project metadata, cues, track mappings into `.amend` package | Project state, waveform cache, cues, room tone | Serialized `project.json` and directory structure | Atomic write failure preserves previous valid state | R3, CONTEXT.md |
| 16 | Storage | Credential Vault | Stores and retrieves cloud API keys securely via macOS Keychain | Provider ID, API Key string | Secure Keychain item (`kSecClassGenericPassword`) | Returns authentication error if key missing or invalid | R3, ADR 0007 |
| 17 | Transcription | FluidAudio Parakeet ASR | Offline word-timestamped transcription running on Core ML / ANE | Narration audio track sample buffer | Word tokens with start/end `CMTime` timestamps | Surfaces transcription error; does not corrupt project | R4, ADR 0002 |
| 18 | Transcription | Silero VAD Engine | Voice Activity Detection for speech segmentation and silence detection | Narration audio track sample buffer | Speech vs non-speech time ranges | Treats entire track as speech if VAD fails | R4, ADR 0002 |
| 19 | Navigation | Interactive Cue Seeking | Clicking a Cue seeks the player to $t_{\text{start}}$ and selects Cue | Cue click event | Video seeks to `Cue.timeRange.start`, playhead updates | Clamped to media duration | R4 |
| 20 | Navigation | Active Cue Highlighting | Real-time visual tracking of the cue active at current playhead time | Player time notification / observer | Active cue state badge highlighted in timeline and transcript | No active highlight when playhead in silence gap | R4 |
| 21 | Room Tone | Room Tone Sampler | Extracts clean 200–500 ms ambient silence slice from source Narration | Source Narration audio, Silero VAD silence segments | Sampled `room_tone.wav` asset | Synthesizes comfort noise if no 200ms silence found | R5, ADR 0005 |
| 22 | Room Tone | Room Tone Loop Padding | Fills residual duration $[t_{\text{synth\_end}}, t_{\text{end}}]$ with looped room tone | Synthesized audio, slot target duration, room tone | Time-matched audio buffer with 10–20ms crossfades | Returns unpadded audio if room tone unavailable | R5, ADR 0005 |
| 23 | Duration Fitting | Automatic Time-Compressor | Offline time compression for audio exceeding slot by $\le 8\%$ | Synthesized audio ($\le +8\%$ duration), target duration | Time-compressed audio matching slot duration exactly | Throws error if rate out of bounds ($> 1.08$) | R5, ADR 0006 |
| 24 | Duration Fitting | Gated Manual Overflow State | Halts automated pipeline and displays exact overflow for audio $> +8\%$ | Synthesized audio ($> +8\%$ duration), slot duration | Gated state with exact overflow delta (e.g. `+1.42s`) | Forbids automated retry loops; awaits user action | R5, ADR 0006 |
| 25 | Duration Fitting | Overflow: Rewrite to Fit | Passes slot duration constraint to LLM to condense text | Gated Cue, target duration constraint | Proposed condensed text | Error if LLM unavailable; manual editing remains open | R5, ADR 0006, R7 |
| 26 | Duration Fitting | Overflow: Force Fit | User-commanded manual override applying extreme pitch-preserved compression | Gated Cue, user confirmation | Compressed audio matching slot duration | Audio may exhibit acoustic artifacts at extreme rates | R5, ADR 0006 |
| 27 | Duration Fitting | Overflow: Split Cue | User splits cue at playhead to reallocate time across slots | Gated Cue, split playhead position $t$ | Two distinct contiguous cues | Rejects split if playhead is at boundary | R5, ADR 0006 |
| 28 | Voice Synthesis | PocketTTS Local Cloning | Pure Swift/CoreML local voice cloning from Reference Voice | Reference Voice sample, cue text | Synthesized WAV buffer matching speaker timbre | Returns synthesis error if model fails to load | R5, ADR 0002 |
| 29 | Voice Synthesis | ElevenLabs Cloud TTS | Cloud voice cloning via ElevenLabs REST API | Reference voice / voice ID, cue text, Keychain API key | Synthesized audio stream / WAV file | HTTP / API error surfaced with retry option | R5 |
| 30 | Voice Synthesis | Resemble Cloud TTS | Cloud voice cloning via Resemble AI REST API | Reference voice / voice ID, cue text, Keychain API key | Synthesized audio stream / WAV file | HTTP / API error surfaced with retry option | R5 |
| 31 | Voice Synthesis | Gemini Natural TTS | Cloud TTS with prebuilt voices; strictly NOT for voice cloning | Selected prebuilt voice ID, cue text, Keychain API key | Synthesized audio stream / WAV file | Hard error if voice cloning requested on Gemini provider | R5 |
| 32 | Voice Synthesis | Reference Voice Extractor | Extracts and prepares 5–15s clean speech sample for voice cloning | Narration track segment or imported audio | Reference Voice asset saved to bundle | Rejects sample if SNR is too low or speech missing | R5, CONTEXT.md |
| 33 | Export | Compressed Video Passthrough | Reads and writes compressed video sample buffers without decoding | Source video track, destination file URL | Bitstream-identical exported video track | Export fails if writer input rejected | R6, ADR 0008 |
| 34 | Export | Passthrough Audio Remuxer | Remuxes unedited audio tracks directly into output container | Passthrough audio tracks, destination file URL | Muxed audio tracks preserving original sample format | Re-encodes only if destination container forbids format | R6, ADR 0008 |
| 35 | Export | Narration Track Rebuilder | Composites modified cues, room tone, and unedited slices into single track | Cue timeline, room tone, unedited narration slices | Continuous linear audio buffer for narration track | Throws composition error if audio gaps exist | R6, ADR 0008 |
| 36 | Export | Presentation Timestamp Sync | Strict preservation of video sample PTS/DTS and total duration matching | Source video sample buffer presentation timestamps | Muxed container with matching duration and PTS | Fails export if output duration deviates from source | R6, ADR 0008 |
| 37 | Export | Fast-Path Passthrough Exporter | Optional fast-path export using `AVAssetExportSession` when verified | Compatible source asset, output URL | Exported movie file via preset passthrough | Falls back to `AVAssetReader`/`Writer` pipeline on failure | R6, ADR 0008 |
| 38 | Script Rewriting | Fix Grammar Action | Corrects grammatical errors, spelling, punctuation via LLM | Current Cue text | Corrected transcript text | Reverts to original text on error or user rejection | R7 |
| 39 | Script Rewriting | Make Natural Action | Refines transcript for conversational flow while retaining terminology | Current Cue text | Natural-phrased transcript text | Reverts to original text on error or user rejection | R7 |
| 40 | Script Rewriting | Restore Original Action | Immediately rolls back edited Cue text to original transcribed text | Edited Cue | Replaced Cue text matching `originalText` | No-op if text has not been edited | R7 |
| 41 | Script Rewriting | Developer Terminology Filter | Enforces preservation of code identifiers, CLI tools, product names, numbers | Raw LLM output, original text tokens | Terminology-validated rewritten text | Rejects or flags rewrite if key identifiers stripped | R7 |
| 42 | Script Rewriting | Text Diff Modal / Popover | Mandatory visual diff presentation (insertions/deletions) before applying | Proposed text, current Cue text | User acceptance or rejection event | Blocks text replacement until explicitly accepted | R7 |
| 43 | Script Rewriting | Pluggable GrammarProvider | Protocol abstracting local Apple Foundation Models and cloud Gemini API | Cue text, prompt mode, duration constraint | Proposed rewritten string | Fails gracefully if provider missing; does not block app | R7 |
| 44 | Model Lifecycle | LocalModelCoordinator | Actor/singleton managing serialized lifecycle and exclusive residency | Model load/unload requests, inference tasks | Serialized execution, bounded memory residency | Rejects concurrent heavy model allocations | R8, ADR 0009 |
| 45 | Model Lifecycle | Exclusive Memory Residency | Guarantees ASR, Local LLM, and PocketTTS are never in RAM simultaneously | Pipeline stage transition event | Deallocated previous model weights, loaded new model | Forces immediate garbage collection / autorelease pool flush | R8, ADR 0009 |
| 46 | Model Lifecycle | Intermediate Disk Caching | Saves ASR tokens, waveform peaks, and synthesized audio WAVs to disk | In-memory inference outputs | Serialized disk files in Project Bundle | Reports disk write failure if volume full | R8, ADR 0009 |
| 47 | Verification | Deterministic Fixture Generator | Programmatic creation of synthetic AVFoundation test assets with tones | Frame rate, dimensions, duration, audio track specs | Synthetic `.mp4`/`.mov` test fixture files | Programmatic failure if fixture parameters invalid | ADR 0007 |
| 48 | Verification | Bitstream Identity Verifier | Compares SHA256 hashes of compressed video sample payloads pre- and post-export | Source video track, exported video track | Identity verification boolean (pass/fail) | Test fails if payload or timestamp altered | ADR 0007, ADR 0008 |

---

## 4. Edge Cases

| # | Feature | Input / Condition | Observed & Specified Behavior |
|---|---------|-------------------|-------------------------------|
| 1 | Audio Track Import | Source recording has exactly 1 audio track | Track is automatically mapped to Narration; UI displays single-track advisory badge; track picker modal is bypassed. |
| 2 | Audio Track Import | Source recording has $> 1$ audio tracks (e.g. mic + system audio) | Track picker modal is presented; user must explicitly select 1 Narration track; unselected tracks become Passthrough Tracks; Track 1 is never assumed to be mic. |
| 3 | Audio Track Import | Source media has 0 audio tracks | Import fails immediately with `ImportError.noAudioTracksFound`; error message presented to user. |
| 4 | Project Media Storage | Destination volume supports APFS cloning and source is on same volume | `FileManager.copyItem` executes APFS copy-on-write clone instantly into `.amend/source.<ext>`; disk usage is 0 additional bytes; `sourceStorageMode = .cloned`. |
| 5 | Project Media Storage | Destination volume does NOT support cloning (FAT32, ExFAT, SMB/NFS, cross-volume) | System refrains from performing multi-gigabyte copy; creates security-scoped bookmark to original media; `sourceStorageMode = .externalBookmark`. |
| 6 | Project Media Storage | Source file moved/renamed after storing security-scoped bookmark | Bookmark resolution attempts resolution with `.withoutUI`; if stale/missing, prompts user to locate media file. |
| 7 | Ambient Room Tone | Narration track contains no silent segment $\ge 200\text{ ms}$ via Silero VAD | Scans for lowest-energy 200ms RMS window in narration track; if entire track has high floor/clipping, synthesizes low-level comfort noise (-60 LUFS). |
| 8 | Duration Fitting | Synthesized audio is shorter than target cue slot ($\Delta \le 0$) | Natural speech rate preserved (never artificially slowed down); speech placed at cue start; remaining gap filled with looped room tone with 10–20ms crossfade. |
| 9 | Duration Fitting | Synthesized audio is exact match for cue slot duration ($\Delta = 0$) | No room tone padding needed; audio placed in slot; 10–20ms boundary crossfades applied at cue start/end. |
| 10 | Duration Fitting | Synthesized audio exceeds slot by $\le 8\%$ ($0 < \Delta \le +8\%$) | Automatically compressed to exact slot duration via offline `AVAudioUnitTimePitch` rendering; vocal pitch preserved; 10–20ms boundary crossfade applied. |
| 11 | Duration Fitting | Synthesized audio exceeds slot by $> 8\%$ ($\Delta > +8\%$) | Enters Gated Manual Overflow state; displays exact overflow (e.g. `+1.42s`); offers `[Rewrite to Fit]`, `[Force Fit]`, `[Split Cue]`; autonomous retry loops forbidden. |
| 12 | Duration Fitting | User chooses "Rewrite to Fit" on overflow cue | LLM is passed cue duration and target speaking rate; produces condensed text; diff modal shown; upon approval, re-synthesizes audio once; no automated loop. |
| 13 | Duration Fitting | User chooses "Force Fit" on overflow cue | Overrides 8% threshold; renders time-compression with `AVAudioUnitTimePitch` at required higher rate; vocal pitch preserved; slot duration satisfied. |
| 14 | Duration Fitting | User chooses "Split Cue" on overflow cue | Cue is split at playhead $t$ into two contiguous cues; user distributes text and synthesizes speech into two separate slots. |
| 15 | Cue Splitting | Split playhead $t \le t_{\text{start}}$ or $t \ge t_{\text{end}}$ | Split operation is rejected (no-op or error); timeline cannot create zero-duration cues. |
| 16 | Cue Splitting | Split playhead $t$ within cue duration | Cue is divided into $[\text{start}, t]$ and $[t, \text{end}]$; zero gap, zero overlap; words/text partitioned; unedited audio or room tone split cleanly. |
| 17 | Sync Invariant | Text edited or audio regenerated in Cue $N$ | Timestamps `start` and `end` of Cue $N+1$ remain completely identical; zero ripple across timeline. |
| 18 | Voice Synthesis | User configures Gemini TTS provider | Gemini TTS is restricted to prebuilt natural voices; voice cloning UI controls disabled; cannot be passed a Reference Voice sample. |
| 19 | Voice Synthesis | User configures PocketTTS / ElevenLabs / Resemble | Voice cloning enabled; Reference Voice sample extracted from narration track or uploaded; model synthesizes cloned voice. |
| 20 | API Security | User enters cloud API keys (ElevenLabs, Resemble, Gemini) | Stored exclusively in macOS Keychain under `kSecClassGenericPassword`; `project.json` contains zero API keys; exported bundle contains zero secrets. |
| 21 | Script Rewriting | LLM rewrite deletes code identifier or product name (e.g. drops `AVAudioEngine`) | Developer terminology validator flags missing identifier; diff modal highlights removal; user can reject change. |
| 22 | Script Rewriting | User invokes "Restore Original" on a modified cue | Current text replaced with `originalText` (persisted on Cue); edit badge updated; regenerates or restores original audio. |
| 23 | Script Rewriting | Network offline or LLM provider fails | Error presented in diff modal; manual editing and local synthesis (PocketTTS) remain fully operational; app does not crash. |
| 24 | Model Memory | ASR transcription running when synthesis request arrives | `LocalModelCoordinator` queues synthesis task; waits for ASR to complete; unloads Parakeet from memory; then loads PocketTTS. |
| 25 | Model Memory | Operating on 8GB Apple Silicon during heavy workflow | Memory footprint stays bounded under ~3.5GB; no simultaneous ASR + PocketTTS + LLM resident; zero system memory pressure warning. |
| 26 | Export Pipeline | Source video has non-zero starting presentation timestamp (PTS) | `AVAssetReader` and `AVAssetWriter` preserve source sample presentation timestamps without rebasing to zero. |
| 27 | Export Pipeline | Passthrough audio track format incompatible with output container (e.g. PCM into MP4) | Export checks container format compatibility; re-encodes only incompatible passthrough track (or alerts user); video remains compressed passthrough. |
| 28 | Timeline Zoom | User zooms out to view entire 1-hour video or in to single second | `pixelsPerSecond` scales visual layers dynamically; playhead seeking remains audio-rate accurate; thumbnails decimate appropriately. |
| 29 | Frame Rates | Video has variable frame rate (VFR) or drop-frame timecode (29.97 fps) | `SwiftTimecode` handles SMPTE drop-frame display calculation; internal `CMTime` remains continuous and exact; no frame rounding of cue boundaries. |

---

## 5. Architectural Specifications & Domain Contracts

### 5.1 Domain Models and Types (Pure Swift)

```swift
import Foundation
import CoreMedia
import AVFoundation

// MARK: - Source Storage Mode
public enum SourceStorageMode: Codable, Equatable {
    case cloned(relativePath: String)
    case externalBookmark(bookmarkData: Data, originalPath: String)
}

// MARK: - Track Routing
public enum AudioTrackRole: String, Codable, Equatable {
    case narration
    case passthrough
}

public struct AudioTrackMapping: Codable, Equatable, Identifiable {
    public let id: Int // CMPersistentTrackID
    public let role: AudioTrackRole
    public let formatName: String
    public let channelCount: Int
    public let sampleRate: Double
    public let languageCode: String?
}

// MARK: - Word Token Model
public struct WordToken: Codable, Equatable, Identifiable {
    public let id: UUID
    public let text: String
    public let timeRange: CMTimeRange
    public let confidence: Float
}

// MARK: - Cue Edit State
public enum CueEditState: String, Codable, Equatable {
    case original
    case edited
    case synthesized
    case roomTonePadded
    case timeCompressed
    case overflowGated
}

// MARK: - Duration Overflow Handling
public enum DurationOverflowAction: Equatable {
    case rewriteToFit
    case forceFit
    case splitCue(splitTime: CMTime)
}

// MARK: - Cue Data Model
public struct Cue: Codable, Equatable, Identifiable {
    public let id: UUID
    public let timeRange: CMTimeRange // Strictly immutable in relation to text edits
    public var text: String
    public let originalText: String
    public var state: CueEditState
    public var words: [WordToken]
    public var synthesizedAudioRelativePath: String?
    public var overflowSeconds: Double? // Populated when state == .overflowGated
    
    public init(
        id: UUID = UUID(),
        timeRange: CMTimeRange,
        text: String,
        originalText: String,
        state: CueEditState = .original,
        words: [WordToken] = [],
        synthesizedAudioRelativePath: String? = nil,
        overflowSeconds: Double? = nil
    ) {
        self.id = id
        self.timeRange = timeRange
        self.text = text
        self.originalText = originalText
        self.state = state
        self.words = words
        self.synthesizedAudioRelativePath = synthesizedAudioRelativePath
        self.overflowSeconds = overflowSeconds
    }
}

// MARK: - Project Bundle Metadata (project.json)
public struct ProjectMetadata: Codable, Equatable {
    public let version: Int
    public let createdAt: Date
    public var modifiedAt: Date
    public var sourceStorageMode: SourceStorageMode
    public var audioTracks: [AudioTrackMapping]
    public var cues: [Cue]
    public var roomToneRelativePath: String?
    public var referenceVoiceRelativePath: String?
    public var frameRate: Double
    public var totalDuration: CMTime
}
```

### 5.2 Provider Protocols

```swift
// MARK: - TTS Provider Protocol
public protocol TTSProvider: AnyObject {
    var providerID: String { get }
    var supportsVoiceCloning: Bool { get }
    
    func synthesizeSpeech(
        text: String,
        referenceVoiceURL: URL?,
        targetDuration: CMTime?
    ) async throws -> URL
}

// MARK: - Grammar & Script Rewrite Provider Protocol
public enum RewriteMode {
    case fixGrammar
    case makeNatural
    case rewriteToFit(targetDuration: CMTime, speakingRateWordsPerMin: Double)
}

public protocol GrammarProvider: AnyObject {
    var providerID: String { get }
    
    func rewriteTranscript(
        text: String,
        mode: RewriteMode,
        context: String?
    ) async throws -> String
}

// MARK: - Local Model Coordinator
public protocol LocalModelCoordinating: AnyObject {
    func requestASRTranscription<T>(
        audioURL: URL,
        execute: @Sendable (URL) async throws -> T
    ) async throws -> T
    
    func requestLocalSynthesis<T>(
        execute: @Sendable () async throws -> T
    ) async throws -> T
    
    func unloadAllModels() async
}
```

---

## 6. Caveats

1. **Hardware Scope**: The architectural rules for memory and model residency assume an 8GB Apple Silicon baseline (M1/M2/M3). Systems with 16GB+ memory could theoretically retain models in RAM, but `LocalModelCoordinator` must enforce serialization and unloading across all hardware variants to ensure deterministic behavior.
2. **Container Compatibility for Passthrough**: MP4 and MOV containers have strict audio format requirements. While compressed video (H.264 / HEVC) passes through bit-for-bit, passthrough audio tracks stored as Linear PCM in MOV may require transcoding if exported to an MP4 container. The export engine must verify container compatibility.
3. **Gemini TTS Voice Cloning Invariant**: Gemini TTS provides prebuilt natural voices only. The architecture forbids treating Gemini as a voice cloning provider or passing reference voice samples to it.
4. **Offline Capability**: Local ASR (Parakeet), VAD (Silero), and voice cloning (PocketTTS) operate completely offline. Cloud providers (ElevenLabs, Resemble, Gemini) require active network access; their absence or network failures must never disrupt core timeline operations, playback, or export.

---

## 7. Conclusion

The architectural specifications for `amend` establish a strict, deterministic, non-rippling media editing system:
1. **Sync Invariant**: Video timestamps are sovereign. Cues are time-locked slots whose boundaries never move during text or audio modifications.
2. **Deterministic Fitting**: Asymmetric duration fitting preserves speech naturalness via room-tone padding, gracefully compresses minor excesses ($\le 8\%$), and strictly gates major overflows ($> 8\%$) behind explicit user choice without autonomous loops.
3. **Storage Efficiency**: APFS copy-on-write cloning ensures instant project bundle creation with zero disk duplication on APFS, falling back gracefully to security-scoped bookmarks elsewhere.
4. **Bitstream Integrity**: Video samples are piped compressed through `AVAssetReader` and `AVAssetWriter`, guaranteeing 100% video bitstream identity and instant export.
5. **Memory Discipline**: `LocalModelCoordinator` enforces mutual exclusion between Core ML ASR and PocketTTS, safeguarding the 8GB Apple Silicon unified memory ceiling.

---

## 8. Verification Method

To independently verify all architectural invariants and specifications, execute the following programmatic verification suites (mandated by ADR 0007):

1. **Sync Invariant Verification**:
   - Inspect: `Tests/SyncInvariantTests.swift`
   - Command: `swift test --filter SyncInvariantTests`
   - Assertion: Across 100 random text edits, audio re-syntheses, and cue splits, verify `Cue[N+1].timeRange.start` remains bit-for-bit identical before and after.
2. **Sample Payload Identity Verification**:
   - Inspect: `Tests/SamplePayloadIdentityTests.swift`
   - Command: `swift test --filter SamplePayloadIdentityTests`
   - Assertion: Compute SHA-256 hashes of every video `CMSampleBuffer` payload extracted from source vs exported file. Must be 100% identical.
3. **Duration Fitting & Gating Verification**:
   - Inspect: `Tests/DurationFittingTests.swift`
   - Command: `swift test --filter DurationFittingTests`
   - Assertion: Audio with $\Delta \le 0$ receives room tone padding with 10–20ms crossfades; audio with $+4\%$ and $+8\%$ is time-compressed to exact slot duration; audio with $+15\%$ enters `.overflowGated` and never auto-loops.
4. **Memory Lifecycle Verification**:
   - Inspect: `Tests/MemoryLifecycleTests.swift`
   - Command: `swift test --filter MemoryLifecycleTests`
   - Assertion: Instruments trace or memory footprint inspection confirms Parakeet ASR and PocketTTS are never concurrently resident; peak memory stays under 3.5GB.
5. **Security & Keychain Verification**:
   - Inspect: `Tests/SecurityTests.swift`
   - Command: `swift test --filter SecurityTests`
   - Assertion: API keys round-trip through Keychain; regex scan of `project.json` and `.amend` bundle contents confirms zero plaintext API keys.
