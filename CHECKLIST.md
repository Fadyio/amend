# Implementation Checklist: Production-Correctness Recovery

## Phase 0: Baseline & Inventory
- [x] Run baseline test suites and inspect failures/timeouts.
- [x] Identify fake implementations: PocketTTS (sine 220Hz), ElevenLabs/Resemble/Gemini TTS (sine 330Hz), Gemini Grammar (string truncation/regex).
- [x] Identify missing track routing: CueGenerator ignores selected narration track ID; PassthroughExportPipeline ignores cues/narration track.
- [x] Identify persistence bugs: AppViewModel does not clone media or persist WAVs inside bundle.
- [x] Document temporary implementation checklist in working branch.

## Phase 1: FluidAudio Migration
- [ ] Upgrade FluidAudio dependency in Package.swift to 0.12.6.
- [ ] Remove obsolete FluidAudioTTS target dependency; import FluidAudio.
- [ ] Implement Silero VAD speech segmentation using VadManager (replace RMS gate).
- [ ] Retain RMS energy detector as separate auxiliary signal (`EnergySilenceDetector`).
- [ ] Add test proving loud tones/noise are rejected by Silero VAD.

## Phase 2: Selected Narration Track Routing
- [ ] Implement AVFoundation track extraction/conversion for selected CMPersistentTrackID to 16kHz Float32 PCM.
- [ ] Validate track IDs before processing.
- [ ] Wire track extraction into CueGenerator (ASR & VAD) and room-tone sampling.
- [ ] Update WaveformExtractor to support extracting specific audio tracks.
- [ ] Add integration test with synthetic two-track movie verifying track routing.

## Phase 3: Real PocketTTS Voice Cloning
- [ ] Delete 220Hz sine-wave synthesis in PocketTTSProvider.
- [ ] Implement PocketTTS using FluidAudio's PocketTtsManager.
- [ ] Support model download state/initialization, voice cloning from reference audio, 24kHz synthesis, and AVAudioPCMBuffer conversion.
- [ ] Add integration/smoke test verifying speech-like PCM and non-sine spectral content.

## Phase 4: Local Model Resource Serialization
- [ ] Audit LocalModelCoordinator for actor reentrancy across suspension points.
- [ ] Implement strict FIFO queuing / exclusive lease lock for heavy Core ML models (ASR, Vad, PocketTTS).
- [ ] Register explicit cleanup/teardown hooks on model transitions.
- [ ] Add concurrency stress test demonstrating serialization without overlapping leases.

## Phase 5: Real Gemini Grammar
- [ ] Remove hardcoded string truncation and replacements from GeminiGrammarProvider.
- [ ] Implement production Gemini REST client via URLSession using Generative Language API (`gemini-1.5-flash` or `gemini-2.0-flash`).
- [ ] Support Fix Grammar, Make Natural, Rewrite to Fit (with target duration and word diff).
- [ ] Handle HTTP status codes, JSON errors, timeouts, and cancellation.
- [ ] Add mock HTTP transport unit tests + opt-in live test with real Keychain credential.

## Phase 6: Real Gemini TTS
- [ ] Implement production Gemini TTS REST client using Cloud TTS / Gemini speech endpoint.
- [ ] Enforce prebuilt voice mode only (reject reference audio).
- [ ] Decode returned audio into AVAudioPCMBuffer without local sine fallback.

## Phase 7: Real ElevenLabs
- [ ] Implement ElevenLabs REST client via URLSession (Instant Voice Clone + TTS).
- [ ] Persist cloned voice_id as non-secret project metadata.
- [ ] Decode audio into AVAudioPCMBuffer without synthetic fallback.

## Phase 8: Resemble AI Provider
- [ ] Implement Resemble AI client via URLSession for TTS and voice cloning.
- [ ] Handle plan capabilities and report actionable errors.

## Phase 9: Provider Settings and Keychain UI
- [ ] Create ProviderSettingsView in macdub app with SecureField for Gemini, ElevenLabs, Resemble.
- [ ] Add "Test Connection", delete, masked display, and PocketTTS model status.
- [ ] Add tests ensuring zero credentials leak into project files or logs.

## Phase 10: Synthesized Audio Storage
- [ ] Store generated Cue WAVs under `<project>.voicefix/audio/cues/cue_<UUID>.wav`.
- [ ] Use relative paths (`audio/cues/cue_<UUID>.wav`) in Cue model.
- [ ] Use managed session working directory for unsaved projects and migrate on Save.

## Phase 11: Project Save/Load Recovery
- [ ] Fix AppViewModel.saveProject() to use ProjectBundleSerializer.
- [ ] Clone source media when on same APFS volume; create security-scoped bookmark otherwise.
- [ ] Persist all Cue metadata, relative WAVs, and room tone.
- [ ] Add round-trip test verifying bundle contents and zero leaked secrets.

## Phase 12: Preview Composition
- [ ] Implement PreviewPlayer / AVMutableComposition generator that splices synthesized Cue WAVs into designated narration track during playback.
- [ ] Keep passthrough tracks and video synchronized.
- [ ] Add integration test verifying preview plays replacement audio in edited intervals.

## Phase 13: Real Narration Reconstruction and Export
- [ ] Rewrite PassthroughExportPipeline to reconstruct designated narration track:
  - Untouched intervals -> original narration track samples.
  - Edited intervals -> generated Cue WAVs + duration fitting / room tone padding.
- [ ] Copy video compressed samples with zero decode/re-encode (`outputSettings: nil`).
- [ ] Copy passthrough audio tracks untouched.
- [ ] Encode reconstructed narration track to AAC/LPCM as container requires.
- [ ] Add test verifying bitstream passthrough for video and replacement audio in exported narration.

## Phase 14: Frame Rate & SMPTE
- [ ] Read source video nominalFrameRate and timescale in AppViewModel.
- [ ] Configure SMPTERulerFormatter and frame stepping to match source media.

## Phase 15 & 16: Assembled App Journey & Test Classification
- [ ] Create assembled E2E test exercising the full journey without mocks:
  - Generate 2-track movie -> Select narration track -> VAD/ASR -> Edit cue -> Synthesize -> Preview -> Save/Load -> Export -> Verify output.
- [ ] Separate unit, integration, assembled E2E, and live-provider tests.

## Phase 17: Final Audit & Gate Status
- [ ] Grep audit for all fake keys, sine waves, stubs, and TODOs.
- [ ] Verify Gates A through N.
- [ ] Update GATE_STATUS.md truthfully.
