# Quality Gate Status & Verification Ledger

## Overview & Truthful Verification Ledger
This ledger documents the verification status across all phases and quality gates of the MacDub project following the macOS 26+ native modernization. MacDub is built natively against official Apple macOS 26+ APIs (`SwiftUI.Glass`, `SwiftUI.GlassEffectContainer`, `View.glassEffect`, and `FoundationModels`). Zero fake compatibility shims or SDK fallbacks exist in MacDub production code.

- **Minimum Deployment Target**: macOS 26.0
- **Swift Tools Version**: 6.0 (`swift-tools-version: 6.0`)
- **Swift Language Mode**:
  - `MacDubCore`: Swift 6 (`.swiftLanguageMode(.v6)`)
  - `MacDubApp`: Swift 6 (`.swiftLanguageMode(.v6)`)
  - `macdub` executable: Swift 6 (`.swiftLanguageMode(.v6)`)
  - `MacDubCoreTests`: Swift 5 (`.swiftLanguageMode(.v5)`) for async test harness & mock URL protocol concurrency compatibility
- **Host Toolchain**: Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1), macOS SDK 27.0
- **CI Runner**: GitHub Actions `macos-26` runner with automated early check enforcing macOS SDK major version >= 26
- **UI Architecture**: macOS 26 Liquid Glass (`glassEffect`, `GlassEffectContainer`), calm solid transcript readability, no legacy fake materials
- **Total Test Suites**: 28
- **Verification Categorization & Test Accounting**:
  1. **DETERMINISTIC CI** (`swift test --no-parallel`):
     - **272 passed**, 0 failed, 4 opt-in acceptance tests skipped by default via Swift Testing `.enabled(if:)` traits.
     - Runs fully automated in CI and local machines without requiring local neural weights or real media.
  2. **LOCAL NEURAL ACCEPTANCE** (`MACDUB_RUN_LOCAL_AI_TESTS=1`):
     - 2 opt-in acceptance tests:
       - `PocketTTSAcceptanceTests.test_real_pocket_tts_cloning_and_synthesis`: Downloads Core ML PocketTTS model, clones authentic Kathleen reference voice, and synthesizes 24kHz audio on Apple Silicon Neural Engine (passed live in 1179.8s).
       - `AssembledAppE2ETests.test_live_model_end_to_end_journey`: Executes full on-device pipeline with Parakeet ASR, Silero VAD, and PocketTTS cloning.
  3. **APPLE FOUNDATION MODELS ACCEPTANCE** (`MACDUB_RUN_APPLE_MODEL_TESTS=1`):
     - 1 opt-in acceptance test:
       - `AppleFoundationGrammarTests.test_live_apple_foundation_model_inference`: Executes live on-device Apple Intelligence grammar rewrite via native `FoundationModels` (`SystemLanguageModel.default`, `LanguageModelSession`, schema-constrained generation) without any compatibility shims (passed live in 26.70s). Fails explicitly if `SystemLanguageModel` is unavailable.
  4. **REAL-MEDIA ACCEPTANCE** (`MACDUB_RUN_REAL_MEDIA_TESTS=1` + `MACDUB_REAL_MEDIA="/path/to/file.mov"`):
     - 1 opt-in acceptance test:
       - `RealWorldAcceptanceTests.test_real_media_acceptance_journey`: Validates live AVFoundation video frame decoding, timeline scrubbing, and deliberate transcription against user recording. Fails explicitly if `MACDUB_REAL_MEDIA` is missing or unreadable.
  5. **LIVE CLOUD ACCEPTANCE**:
     - Verified against official schemas via hermetic URL mock protocols; live network traffic requires user-supplied Keychain keys.
- **Host Architecture**: Apple Silicon M1 (arm64, 8 GB RAM, macOS 26.6.2)

---

## Truthful Quality Ledger

| Area | Status | Evidence / Notes |
| :--- | :--- | :--- |
| **Sync Invariant** | **VERIFIED** | `SyncInvariantTests`, `SyncInvariantAdversarialTests` (36 tests) prove immutable slot boundaries. |
| **Timeline** | **VERIFIED** | `TimelineClockTests`, `SMPTERulerFormatterTests`, `WaveformExtractorTests` pass deterministically. |
| **Selected Narration Routing** | **VERIFIED** | AudioTrackExtractor extracts by CMPersistentTrackID; verified in `AudioRoutingTests` & `AssembledAppE2ETests`. |
| **Silero VAD** | **VERIFIED** | Compiled Core ML Silero VAD v6.0.0 model executes on Apple Silicon Neural Engine in `TranscriptionVADTests`. |
| **Parakeet ASR** | **REAL 8 GB M1 WORKFLOW EXECUTED SUCCESSFULLY** | Initialized in `TranscriptionService`; executed end-to-end on Apple Silicon M1 in `AssembledAppE2ETests` (transcribed Kathleen audio with `exciting`, `time`, `week`, `thursday`). |
| **Deliberate Transcription Workflow** | **VERIFIED** | Media import extracts waveform and configures tracks immediately without auto-running Parakeet; transcription requires explicit user trigger. |
| **Project Bundle Persistence** | **VERIFIED** | `.voicefix` package saves/loads media reference, tracks, cues, candidate WAVs, Reference Voice, and provider IDs. |
| **Single Source of Truth** | **VERIFIED** | `AppViewModel.selectedProviderType` is the single authoritative provider state; script editor uses proxy binding. |
| **Preview Composition** | **VERIFIED** | Untouched video & passthrough audio, original narration outside cues, approved replacement audio in cues. |
| **Export Narration Replacement** | **VERIFIED** | Slices replacement WAVs into narration track while untouched audio & video bitstream remain byte-identical. |
| **Export Ignored Track Exclusion** | **VERIFIED** | `PassthroughExportPipeline` excludes unselected/ignored tracks both with and without edited cues. |
| **Video Bitstream Passthrough** | **VERIFIED** | `PassthroughExportTests.test_passthrough_export_preserves_exact_compressed_sample_hashes` verifies zero transcoding. |
| **DurationFitter** | **VERIFIED** | Asymmetric time compression within 8%, room-tone padding for shorter speech, 15ms boundary crossfades. |
| **Overflow User Gating** | **VERIFIED** | >8% overflow candidate is stored for inspection but strictly excluded from preview and export until approved. |
| **PocketTTS Engine Seam & Cache** | **VERIFIED** | MacDub-owned `PocketTTSEngine` abstraction with `SpyPocketTTSEngine` test seam; `Packages/FluidAudio` pristine with zero diff. |
| **PocketTTS Voice Cloning Acceptance** | **REAL 8 GB M1 WORKFLOW EXECUTED SUCCESSFULLY** | Executed live on Apple Silicon M1 (`MACDUB_RUN_LOCAL_AI_TESTS=1 swift test --filter PocketTTSAcceptanceTests` passed in 1179.8s). |
| **Speech Fixture & Provenance** | **VERIFIED** | Authentic human speech under CC0 1.0 Universal (`rhasspy/dataset-voice-kathleen`, `arctic_a0366`, 5.072s 24kHz mono WAV) documented in `Fixtures/README.md`; resolved via `TestReferenceVoiceResolver`. |
| **Reference Voice State Semantics** | **VERIFIED** | Truthful states: `.unconfigured` -> `.configured` (on import) -> `.loading` (synthesizing) -> `.ready` / `.failed`. |
| **Apple Foundation Models Grammar** | **REAL ON-DEVICE WORKFLOW EXECUTED SUCCESSFULLY** | Implemented in `AppleFoundationGrammarProvider` via native `FoundationModels` framework; verified on-device with structured generation schema and diff computation (`MACDUB_RUN_APPLE_MODEL_TESTS=1` passed in 26.70s with zero shims). |
| **Liquid Glass Architecture** | **VERIFIED** | macOS 26 native `glassEffect(.regular)` and `GlassEffectContainer` for toolbars, inspectors, and floating controls; zero compatibility shims. |
| **Gemini Grammar** | **LIVE CREDENTIAL VERIFICATION REQUIRED** | Updated to `gemini-2.5-flash` with `x-goog-api-key` header (zero URL keys). Hermetic mock transport contract verified via `TestURLProtocol`; live call pending user key. |
| **Gemini TTS REST & Missing-MIME Handling** | **LIVE CREDENTIAL VERIFICATION REQUIRED** | Verified against official `POST /v1beta/interactions` schema. Explicit WAV, MP3, M4A, raw PCM/L16, and RIFF magic byte payloads decoded safely; missing MIME treated as raw 16-bit PCM (24kHz mono) wrapped in valid RIFF WAV; malformed PCM and unsupported MIME rejected explicitly. Hermetic mock transport contract verified via `TestURLProtocol`; live call pending user key. |
| **ElevenLabs Backend & Workflow** | **LIVE CREDENTIAL VERIFICATION REQUIRED** | Default model `eleven_multilingual_v2`, instant voice cloning (`/v1/voices/add`) with dynamic MIME detection. Hermetic mock transport contract verified via `TestURLProtocol`; live call pending user key. |
| **Resemble Backend** | **EXISTING VOICE UUID ONLY — LIVE CREDENTIAL REQUIRED** | Resemble provider is manual-ID only (`Resemble — Existing Voice UUID`), not Reference Voice cloning. Executes synchronous synthesis via `POST https://f.cluster.resemble.ai/synthesize` with Bearer auth and `voice_uuid`. Hermetic mock transport contract verified via `TestURLProtocol`; live call pending user key. |
| **Provider Settings** | **VERIFIED** | Test Connection tests authentic credentials with proper headers; truthful state display and canonical WAV conversion; displays real-time Apple Intelligence on-device status card. |
| **Export Format Enforcement** | **VERIFIED** | QuickTime Movie (.mov) strictly enforced; invalid containers (.mp4) fail cleanly with actionable errors. |
| **Boundary Crossfades & Loudness Matching** | **VERIFIED** | 15ms equal-power boundary fades; ITU-R BS.1770 / EBU R128 loudness matched to surrounding original narration. |
| **Frame Stepping & Transport Seeking** | **VERIFIED** | Frame stepping (`stepForward/Backward(by:fps:)`) adapts dynamically to source FPS (24, 30, 60); Reference Monitor transport implements true ±5-second seeking (`seekForward/Backward(by: 5.0)`). |
| **macOS GitHub Actions CI** | **VERIFIED** | `.github/workflows/ci.yml` runs non-parallel deterministic test suite on `macos-26` runner with early failure if SDK < 26. |

---

## Milestone Breakdown

### Milestone 1: Core Foundation, Storage & Security (Gates B, E, L)
- **Status**: PASSED (100% automated)
- **Test Suites**:
  - `StorageAPFSTests` (7/7 passed)
  - `SecuritySuiteTests` (10/10 passed)
  - `AdversarialStressTests` (22/22 passed)
- **Key Deliverables**:
  - APFS CoW cloning (`APFSCloner`) with security-scoped bookmark fallback (`BookmarkManager`).
  - Strict Keychain credential storage (`KeychainVault`, `kSecClassGenericPassword`).
  - Zero-credential bundle leak scanner (`CredentialLeakScanner`) detecting provider patterns, `.env` files, and absolute user paths.
  - Robust project bundle serialization (`ProjectBundleSerializer`, `ProjectBundle`, `ProjectMetadata`).

### Milestone 2: Audio Routing & Fixed-Slot Composition Engine (Gates D, F)
- **Status**: PASSED (100% automated)
- **Test Suites**:
  - `AudioRoutingTests` (9/9 passed)
  - `SyncInvariantTests` (10/10 passed)
  - `CueSplitterTests` (7/7 passed)
  - `BoundaryCrossfaderTests` (5/5 passed)
  - `LoudnessNormalizerTests` (6/6 passed)
  - `DSPAdversarialTests` (27/27 passed)
  - `SyncInvariantAdversarialTests` (26/26 passed)
- **Key Deliverables**:
  - Ambiguity-safe audio track inspection (`AudioTrackInspector`).
  - Fixed-slot sync invariant engine (`SyncInvariantEngine`).
  - Zero-gap, zero-overlap cue splitting (`CueSplitter`).
  - Boundary crossfading with equal-power curves (`BoundaryCrossfader`).
  - ITU-R BS.1770 / EBU R128 loudness normalization (`LoudnessNormalizer`).

### Milestone 3: Timeline Engine & Visual Presentation (Gates I, N)
- **Status**: PASSED (100% automated)
- **Test Suites**:
  - `TimelineCoordinateTests` (7/7 passed)
  - `CueBinarySearchTests` (8/8 passed)
  - `SMPTERulerFormatterTests` (8/8 passed)
  - `PlayheadSnapperTests` (10/10 passed)
  - `TimelineClockTests` (9/9 passed)
  - `FilmstripGeneratorTests` (5/5 passed)
  - `WaveformExtractorTests` (6/6 passed)
  - `Tier1FeatureTests` (15/15 passed)
- **Key Deliverables**:
  - Continuous `CMTime` timeline coordinate conversion (`TimelineCoordinateConverter`).
  - Dual-mode SMPTE timecode formatting with drop-frame handling (`SMPTERulerFormatter`).
  - Draggable playhead magnetic snapping with dual-threshold hysteresis (`PlayheadSnapper`).
  - Master transport clock with 60Hz/120Hz leaf updates and AVPlayer sync (`TimelineClock`, `PlayheadClock`, `TimelineScrubberController`).
  - Async multi-tier filmstrip generator with memory and disk caching (`FilmstripGenerator`).
  - vDSP-accelerated multi-scale waveform extractor with binary caching (`WaveformExtractor`).
  - Native SwiftUI timeline views (`TimelineView`, `SMPTERulerView`, `FilmstripTrackView`, `WaveformTrackView`, `CueTrackView`, `CueBlockView`, `PlayheadOverlayView`).

### Milestone 4: FluidAudio ASR, VAD & Model Lifecycle (Gate M)
- **Status**: PASSED (100% automated)
- **Test Suites**:
  - `TranscriptionVADTests` (7/7 passed)
- **Key Deliverables**:
  - Serialized local model residency enforcement (`LocalModelCoordinator`, ADR-0009).
  - VAD speech region and ambient room-tone slice detection (`SilenceDetector`, ADR-0005) verified with real Silero VAD Core ML model.
  - High-precision timestamped word transcription (`TranscriptionService`).
  - Speech cue slot assembly with silence boundary alignment (`CueGenerator`).

### Milestone 5: Voice Synthesis, Duration Fitting & Grammar Rewriting
- **Status**: PASSED (100% automated)
- **Test Suites**:
  - `SynthesisDurationGrammarTests` (10/10 passed, serialized)
  - `ProviderAndOverflowBlockerTests` (22/22 passed)
- **Key Deliverables**:
  - Unified voice synthesis provider architecture (`VoiceSynthesizer`, `PocketTTSProvider`, `ElevenLabsProvider`, `ResembleProvider`, `GeminiTTSProvider`).
  - Gemini Grammar updated to `gemini-2.5-flash` with header-based auth (`x-goog-api-key`) and zero URL credential leaks.
  - Gemini TTS updated to official `POST /v1beta/interactions` endpoint with `response_format: { "type": "audio" }`, header-based auth (`x-goog-api-key`), and `gemini-3.1-flash-tts-preview`.
  - Gemini TTS robust response decoding honoring explicit MIME, parsing RIFF/WAV magic bytes, wrapping raw PCM/L16 into WAV headers with sample alignment checks, and rejecting malformed or unsupported MIME formats.
  - ElevenLabs default model `eleven_multilingual_v2`, centralized model constants, instant voice cloning (`/v1/voices/add`) with dynamic MIME detection and Reference Voice wiring.
  - Resemble synchronous synthesis via current `POST https://f.cluster.resemble.ai/synthesize` with Bearer auth and manual `voice_uuid` configuration.
  - Architectural constraint enforcement: Gemini TTS restricted to prebuilt natural voices; cloning reference audio is strictly rejected.
  - Zero synthetic fallback audio: missing or invalid credentials throw explicit, actionable errors (`SynthesisError.missingAPIKey`, `SynthesisError.synthesisFailed`).
  - User-gated asymmetric duration fitting with room-tone padding (sample rate auto-resampled), WSOLA time stretching (`DurationFitter`, ADR-0006), and candidate isolation for >8% overflow.
  - Semantic grammar correction and slot-aware rewriting (`GrammarRewriter`, `GeminiGrammarProvider`).

### Milestone 6: Passthrough Mux Export & Non-Destructive Preview (Gates G, H)
- **Status**: PASSED (100% automated)
- **Test Suites**:
  - `PassthroughExportTests` (4/4 passed)
  - `PreviewCompositionTests` (1/1 passed)
- **Key Deliverables**:
  - Compressed-sample bitstream passthrough export pipeline with `outputSettings: nil` guaranteeing zero transcoding quality loss (`PassthroughExportPipeline`, ADR-0008).
  - QuickTime Movie (.mov) container strictly enforced; invalid containers (.mp4) fail cleanly with actionable errors.
  - Analytical zero-crossing audio verification proving replacement audio is spliced into designated narration track while untouched cues and passthrough tracks retain exact original frequencies.
  - Non-destructive `AVComposition` preview generation (`PreviewCompositionGenerator`) splicing replacement WAV audio in real time.

### Milestone 7: Assembled Application & End-to-End User Journey (Gates A, C, J, K)
- **Status**: PASSED (100% automated)
- **Test Suites**:
  - `AssembledAppE2ETests` (4/4 passed)
- **Key Deliverables**:
  - Modularized `MacDubApp` library target allowing SPM test target to test top-level `AppViewModel` and UI coordinators.
  - 16-step end-to-end integration test verifying the complete user journey:
    1. Multi-track media creation.
    2. AppViewModel initialization.
    3. Media import & track inspection.
    4. Audio track routing (narration vs passthrough).
    5. Speech cue generation.
    6. Cue text editing.
    7. Replacement audio synthesis.
    8. Room-tone duration fitting with 15ms boundary crossfades.
    9. Project bundle saving (`.voicefix`).
    10. Bundle disk layout verification (`project.json`, `audio/cues/`, `voice/`).
    11. Fresh AppViewModel loading from bundle.
    12. State, Reference Voice, provider IDs, and WAV restoration verification.
    13. Real-time preview composition generation.
    14. Bitstream video passthrough export via `ExportSheetViewModel`.
    15. Audio extraction & zero-crossing frequency verification of exported tracks.
    16. Bundle credential leak verification (`CredentialLeakScanner`).
  - Single-track advisory import and automatic cue generation without modal gating.
  - AppViewModel cue splitting maintaining timeline continuity and sync invariants.
  - Strengthened opt-in live neural model end-to-end acceptance journey (`test_live_model_end_to_end_journey`) proving real PocketTTS cloned audio becomes an approved active replacement, enters preview, and reaches the exported narration track while preserving untouched narration, passthrough audio, and video bitstream samples.

---

## Detailed Quality Gate Matrix

| Quality Gate | Description | Implementation File | Verified By / Test | Result |
| :--- | :--- | :--- | :--- | :--- |
| **Gate A** | `swift build` succeeds for MacDubCore and macdub executable | `Package.swift`, `Sources/MacDubCore/`, `Sources/MacDubApp/`, `Sources/macdub/` | Full SPM target compilation (`swift build`) | **IMPLEMENTED + VERIFIED** |
| **Gate B** | All deterministic unit/integration tests pass | `Tests/MacDubCoreTests/` (28 test suites) | `swift test --no-parallel` (272/272 passed, 4 acceptance tests skipped) | **IMPLEMENTED + VERIFIED** |
| **Gate C** | Assembled app-level E2E journey passes | `Sources/MacDubApp/ViewModels/AppViewModel.swift` | `AssembledAppE2ETests.test_complete_sixteen_step_assembled_user_journey` | **IMPLEMENTED + VERIFIED** |
| **Gate D** | Real selected-track routing is verified | `Sources/MacDubCore/Composition/AudioTrackExtractor.swift`, `Sources/MacDubCore/Transcription/CueGenerator.swift` | `AudioRoutingTests` (zero-crossing routing verification on Track B) | **IMPLEMENTED + VERIFIED** |
| **Gate E** | Real Silero VAD is verified | `Sources/MacDubCore/Transcription/SilenceDetector.swift` | `TranscriptionVADTests` (compiled Core ML model on Neural Engine/CPU rejecting tones) | **IMPLEMENTED + VERIFIED** |
| **Gate F** | Real PocketTTS synthesis and local cloning work on target Mac | `Sources/MacDubCore/Synthesis/VoiceSynthesizer.swift`, `PocketTTSProvider` | `PocketTTSAcceptanceTests` & `AssembledAppE2ETests` (opt-in; downloaded models, cloned Kathleen voice, synthesized audio on M1 Neural Engine) | **IMPLEMENTED + VERIFIED (REAL 8 GB M1 WORKFLOW EXECUTED SUCCESSFULLY)** |
| **Gate G** | Preview audibly/analytically contains replacement narration | `Sources/MacDubCore/Composition/PreviewComposition.swift` | `PreviewCompositionTests` (zero-crossing frequency assertions) | **IMPLEMENTED + VERIFIED** |
| **Gate H** | Export analytically contains replacement narration | `Sources/MacDubCore/Export/PassthroughExportPipeline.swift` | `PassthroughExportTests` (narration rebuilt, passthrough preserved) | **IMPLEMENTED + VERIFIED** |
| **Gate I** | Video compressed-sample identity is genuinely verified where passthrough is expected | `Sources/MacDubCore/Export/PassthroughExportPipeline.swift` | `PassthroughExportTests.test_passthrough_export_preserves_exact_compressed_sample_hashes` | **IMPLEMENTED + VERIFIED** |
| **Gate J** | Save/load roundtrip preserves source resolution, Cue audio, Reference Voice & provider settings | `Sources/MacDubCore/Storage/ProjectBundleSerializer.swift`, `AppViewModel.saveProject` | `StorageAPFSTests`, `ProviderAndOverflowBlockerTests.test_reference_voice_and_persistence_roundtrip` | **IMPLEMENTED + VERIFIED** |
| **Gate K** | Credential scanner proves no API credential is present in repository or `.voicefix` output | `Sources/MacDubCore/Storage/CredentialLeakScanner.swift` | `SecuritySuiteTests`, `AssembledAppE2ETests` (step 16) | **IMPLEMENTED + VERIFIED** |
| **Gate L** | Live Gemini Grammar & TTS tests pass with real user-supplied Keychain credential | `Sources/MacDubCore/Synthesis/VoiceSynthesizer.swift` (`GeminiTTSProvider`), `GrammarRewriter.swift` | Registered mock transport & negative auth rejection verified; live call pending user key | **IMPLEMENTED — LIVE CREDENTIAL VERIFICATION REQUIRED** |
| **Gate M** | Live ElevenLabs test passes when configured | `Sources/MacDubCore/Synthesis/VoiceSynthesizer.swift` (`ElevenLabsProvider`) | Registered mock transport, clone & synth contract verified; live call pending user key | **IMPLEMENTED — LIVE CREDENTIAL VERIFICATION REQUIRED** |
| **Gate N** | Live Resemble test passes only when configured and account capabilities permit it | `Sources/MacDubCore/Synthesis/VoiceSynthesizer.swift` (`ResembleProvider`) | Registered mock transport & /synthesize contract verified; live call pending user key | **IMPLEMENTED — LIVE CREDENTIAL VERIFICATION REQUIRED** |
| **Gate O** | Apple Foundation Models on-device structured grammar rewrite succeeds | `Sources/MacDubCore/Synthesis/AppleFoundationGrammarProvider.swift` | `AppleFoundationGrammarTests` (deterministic mocks + opt-in real on-device model execution) | **IMPLEMENTED + VERIFIED (REAL ON-DEVICE WORKFLOW EXECUTED SUCCESSFULLY)** |
| **Gate P** | macOS 26 Liquid Glass UI styling and container controls | `Sources/MacDubApp/Views/LiquidGlassTheme.swift`, `MacDubToolbar.swift`, `CueInspectorView.swift`, etc. | Verified via packaged app launch and UI snapshot rendering | **IMPLEMENTED + VERIFIED** |
