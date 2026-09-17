# BRIEFING — 2026-09-16T12:44:00Z

## Mission
Extract and catalog all architectural specifications, domain invariants, data structures, and constraints for macdub from ORIGINAL_REQUEST.md, CONTEXT.md, and ADRs 0001-0009.

## 🔒 My Identity
- Archetype: Specification Miner
- Roles: Architecture & ADR Spec Miner
- Working directory: /Users/fady/Dev/macdub/.agents/spec_miner_adr_0
- Original parent: 7ec3ddce-95f5-49a5-a77f-54809810b3da
- Milestone: Milestone 0 - Specification Mining

## 🔒 Key Constraints
- READ-ONLY on source code and project files. Write only to /Users/fady/Dev/macdub/.agents/spec_miner_adr_0.
- Do NOT implement anything. Discover and document features, domain invariants, data models, error behaviors, and constraints.
- Output final report to /Users/fady/Dev/macdub/.agents/spec_miner_adr_0/handoff.md following 5-Component Handoff format + Features Discovered and Edge Cases tables.
- Maintain progress.md with timestamp heartbeats.
- Communicate results via send_message to caller (id: 7ec3ddce-95f5-49a5-a77f-54809810b3da, name: parent).

## Current Parent
- Conversation ID: 7ec3ddce-95f5-49a5-a77f-54809810b3da
- Updated: not yet

## Task Summary
- **What to build**: Complete architectural specification catalog covering 7 core areas:
  1. Fixed-sync invariant & timeline time vs display timecode, Cue data model, splitting semantics, boundary crossfades (R1, R2).
  2. Native Swift & CoreML stack constraints, FluidAudio (Parakeet ASR, Silero VAD), PocketTTS, cloud TTS (ElevenLabs, Resemble, Gemini non-cloning) (R4, R5).
  3. Ambiguity-safe audio track mapping & track picker, APFS clone-first vs security-scoped bookmarks storage, project bundle layout (.voicefix, project.json) (R3).
  4. Ambient room-tone sampling (200-500ms VAD silence) & crossfade padding, asymmetric duration fitting (<=8% AVAudioUnitTimePitch, >8% gated manual overflow with 3 choices) (R5).
  5. Compressed-sample passthrough export pipeline (AVAssetReader/AVAssetWriter, compressed sample preservation, passthrough tracks, duration match) (R6).
  6. Grammar correction and script rewriting, diff modal, duration constraints, provider protocols (R7).
  7. Serialized local model lifecycle (LocalModelCoordinator, 8GB Apple Silicon budget, exclusive residency, caching) (R8).
- **Success criteria**: Comprehensive feature tables, edge case tables, domain invariant catalogs, and 5-component handoff report.
- **Interface contracts**: CONTEXT.md, ADR 0001-0009, ORIGINAL_REQUEST.md
- **Code layout**: Read-only inspection of repository structure and docs.

## Key Decisions Made
- Initialized spec mining structure.
- Fully probed all 9 ADRs, CONTEXT.md, and ORIGINAL_REQUEST.md (R1-R8).
- Cataloged 48 discrete features across 10 architectural categories in `handoff.md`.
- Documented 29 specific edge cases and error behaviors.
- Formulated exact Swift domain models and provider protocols for Cue, TrackMapping, DurationFitting, LocalModelCoordinating, TTSProvider, and GrammarProvider.
- Compiled self-contained 5-component Handoff Report in `handoff.md`.

## Artifact Index
- /Users/fady/Dev/macdub/.agents/spec_miner_adr_0/DISPATCH.md — Initial dispatch log
- /Users/fady/Dev/macdub/.agents/spec_miner_adr_0/BRIEFING.md — Persistent working memory
- /Users/fady/Dev/macdub/.agents/spec_miner_adr_0/progress.md — Liveness heartbeat and step tracking
- /Users/fady/Dev/macdub/.agents/spec_miner_adr_0/handoff.md — Comprehensive final handoff report

## Loaded Skills
- None explicitly assigned.
