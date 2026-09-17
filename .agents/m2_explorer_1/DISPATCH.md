# Dispatch — m2_explorer_1
Target: Exploration and architecture proposal for Milestone 2: Audio Routing & Fixed-Slot Composition Engine.
Directory: /Users/fady/Dev/macdub/.agents/m2_explorer_1

## 2026-09-16T17:40:44Z
You are m2_explorer_1, an exploration agent for Milestone 2: Audio Routing & Fixed-Slot Composition Engine.
Your working directory is /Users/fady/Dev/macdub/.agents/m2_explorer_1.
Read /Users/fady/Dev/macdub/ORIGINAL_REQUEST.md and /Users/fady/Dev/macdub/.agents/orchestrator_6/PROJECT.md.

Task:
1. Explore the architecture and requirements for Milestone 2:
   - AudioTrackInspector: inspect audio tracks of source media via AVURLAsset, determine track count, detect channels/sample rates, auto-assign single track with advisory badge, or provide multi-track mapping structure for TrackPicker modal (designating Narration track ID and Passthrough track IDs).
   - SyncInvariantEngine: enforce fixed-slot timeline invariant where editing Cue[N] guarantees Cue[N+1] boundaries remain immutable. Support continuous CMTime calculation without cumulative drift.
   - CueSplitter: split a Cue at continuous timestamp t into [start, t] and [t, end] with exactly 0 gap and 0 overlap, maintaining exact rational CMTime precision.
   - BoundaryCrossfader: apply 10–20ms crossfading at cue boundaries (linear and equal-power options) to eliminate audio clicks/pops.
   - LoudnessNormalizer: calculate RMS and LUFS levels for replacement audio and apply gain adjustment to match original narration level.
2. Review existing models in Sources/MacDubCore/Models/ (Cue, AudioTrackMapping, ProjectMetadata, etc.) and identify needed extensions or helper methods.
3. Formulate a complete design and implementation plan for:
   - Sources/MacDubCore/Composition/AudioTrackInspector.swift
   - Sources/MacDubCore/Composition/SyncInvariantEngine.swift
   - Sources/MacDubCore/Composition/CueSplitter.swift
   - Sources/MacDubCore/Composition/BoundaryCrossfader.swift
   - Sources/MacDubCore/Composition/LoudnessNormalizer.swift
   - Tests/MacDubCoreTests/Suites/AudioRoutingTests.swift
   - Tests/MacDubCoreTests/Suites/SyncInvariantTests.swift
4. Write your comprehensive exploration report to /Users/fady/Dev/macdub/.agents/m2_explorer_1/handoff.md.
Send a message to your parent (conversation ID: 4d531adf-45c7-4a43-8701-f7617acd84e7) with a summary of your findings and recommendations.
