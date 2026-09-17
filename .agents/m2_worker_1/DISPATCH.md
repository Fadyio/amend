## 2026-09-16T18:27:00Z
You are m2_worker_1, an implementation worker for Milestone 2: Audio Routing & Fixed-Slot Composition Engine.
Your working directory is /Users/fady/Dev/macdub/.agents/m2_worker_1.
Read:
- /Users/fady/Dev/macdub/ORIGINAL_REQUEST.md
- /Users/fady/Dev/macdub/.agents/orchestrator_6/PROJECT.md
- /Users/fady/Dev/macdub/.agents/m2_explorer_1/handoff.md (comprehensive architectural and code specifications for M2)
- /Users/fady/Dev/macdub/.agents/m1_auditor_6/handoff.md (contains M1 concurrency and leak scanner findings)

DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A teamwork_preview_auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

Tasks:
1. Polish Milestone 1 components:
   - In Sources/MacDubCore/Storage/KeychainVault.swift: Add an internal NSLock around macOS Security framework C calls (SecItemAdd, SecItemUpdate, SecItemCopyMatching, SecItemDelete) to ensure thread-safe concurrency and prevent securityd lock contention.
   - In Sources/MacDubCore/Storage/CredentialLeakScanner.swift: In `scan(bundleURL:)`, ensure that all JSON and text files in the bundle (e.g. config.json) are checked for absolute user paths (`/Users/...`).
2. Implement Milestone 2 in Sources/MacDubCore/Composition/:
   - AudioTrackInspector.swift: Asynchronously load audio tracks via AVURLAsset.loadTracks(withMediaType: .audio), extract format, channel count, sample rate, bit depth, time range; handle 1 track (auto-assign narration, isSingleTrackAdvisory = true) vs >1 tracks (multi-track mapping proposal for modal); validate mappings.
   - SyncInvariantEngine.swift: Enforce fixed-slot timeline invariant: editing Cue[N] guarantees all other cues remain immutable in start, duration, end; validate contiguous layout; rational CoreMedia math without floating-point drift or frame rounding.
   - CueSplitter.swift: Split a cue at playhead CMTime t into [start, t] and [t, end] with proven 0 gap and 0 overlap, preserving neighbor boundaries.
   - BoundaryCrossfader.swift: 10–20ms crossfader (linear and equal-power options via Accelerate vDSP / math) to eliminate boundary clicks/pops; handles short buffers safely.
   - LoudnessNormalizer.swift: Vectorized RMS measurement via vDSP and LUFS estimation; gain calculation and application with peak ceiling protection (e.g. 0.95 / -0.45 dBFS).
3. Implement Unit Tests in Tests/MacDubCoreTests/Suites/:
   - AudioRoutingTests.swift: Tests single-track advisory badge, multi-track mapping, invalid mappings, format extraction.
   - SyncInvariantTests.swift: Tests fixed-slot invariant across text edits and audio replacements, zero-gap cue splitting, boundary crossfader equal-power curves, loudness normalization.
4. Run `swift build` and `swift test` using command line tools. Ensure all tests pass.
5. Document all changes and verification outputs in /Users/fady/Dev/macdub/.agents/m2_worker_1/handoff.md.
Send a message to your parent (conversation ID: 4d531adf-45c7-4a43-8701-f7617acd84e7) when complete.
