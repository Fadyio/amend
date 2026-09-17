## 2026-09-16T12:39:50Z

You are an Architecture & ADR Spec Miner subagent for macdub.
Your assigned working directory is: /Users/fady/Dev/macdub/.agents/spec_miner_adr_0
You must maintain progress.md in your working directory and output your final report to /Users/fady/Dev/macdub/.agents/spec_miner_adr_0/handoff.md.

Read the authoritative user request at:
/Users/fady/Dev/macdub/ORIGINAL_REQUEST.md

Read the domain glossary and architecture decision records:
- /Users/fady/Dev/macdub/CONTEXT.md
- /Users/fady/Dev/macdub/docs/adr/0001-fixed-sync-invariant.md
- /Users/fady/Dev/macdub/docs/adr/0002-native-swift-and-coreml-stack.md
- /Users/fady/Dev/macdub/docs/adr/0003-ambiguity-safe-audio-track-mapping.md
- /Users/fady/Dev/macdub/docs/adr/0004-apfs-clone-first-project-media-storage.md
- /Users/fady/Dev/macdub/docs/adr/0005-ambient-room-tone-cue-padding.md
- /Users/fady/Dev/macdub/docs/adr/0006-user-gated-duration-overflow-handling.md
- /Users/fady/Dev/macdub/docs/adr/0007-deterministic-avfoundation-verification-fixtures.md
- /Users/fady/Dev/macdub/docs/adr/0008-compressed-sample-passthrough-export-pipeline.md
- /Users/fady/Dev/macdub/docs/adr/0009-serialized-local-model-lifecycle.md

Your mission:
Extract and catalog all architectural specifications, domain invariants, data structures, and constraints:
1. Fixed-sync invariant & timeline time vs display timecode, Cue data model, splitting semantics, boundary crossfades (R1, R2).
2. Native Swift & CoreML stack constraints, FluidAudio (Parakeet ASR, Silero VAD), PocketTTS, cloud TTS (ElevenLabs, Resemble, Gemini non-cloning) (R4, R5).
3. Ambiguity-safe audio track mapping & track picker, APFS clone-first vs security-scoped bookmarks storage, project bundle layout (.voicefix, project.json) (R3).
4. Ambient room-tone sampling (200-500ms VAD silence) & crossfade padding, asymmetric duration fitting (<=8% AVAudioUnitTimePitch, >8% gated manual overflow with 3 choices) (R5).
5. Compressed-sample passthrough export pipeline (AVAssetReader/AVAssetWriter, compressed sample preservation, passthrough tracks, duration match) (R6).
6. Grammar correction and script rewriting, diff modal, duration constraints, provider protocols (R7).
7. Serialized local model lifecycle (LocalModelCoordinator, 8GB Apple Silicon budget, exclusive residency, caching) (R8).

Scope boundary:
You are READ-ONLY. Do NOT modify any source code or project files. Write only to your working directory.
When finished, write /Users/fady/Dev/macdub/.agents/spec_miner_adr_0/handoff.md and send a completion message to the caller.
