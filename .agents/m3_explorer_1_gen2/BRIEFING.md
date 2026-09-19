# BRIEFING — 2026-09-16T21:15:30Z

## Mission
Investigate and design the architectural foundation for Milestone 3 (TimelineClock, SMPTERulerFormatter, Magnetic Snapping, and Timeline Engine integration) without modifying source code.

## 🔒 My Identity
- Archetype: explorer
- Roles: investigation, synthesis
- Working directory: /Users/fady/Dev/amend/.agents/m3_explorer_1_gen2
- Original parent: b34c3ff6-40fb-40eb-9abe-6faa574a682f
- Milestone: Milestone 3 (Timeline Engine & Visual Presentation)

## 🔒 Key Constraints
- Read-only investigation — do NOT implement source code
- Inspect existing codebase, Package.swift, Sources/AmendCore/Timeline
- Focus on TimelineClock, SMPTERulerFormatter, Magnetic Snapping, and AVPlayer sync
- Produce 5-component handoff report at /Users/fady/Dev/amend/.agents/m3_explorer_1_gen2/handoff.md
- Notify parent orchestrator via send_message upon completion

## Current Parent
- Conversation ID: b34c3ff6-40fb-40eb-9abe-6faa574a682f
- Updated: 2026-09-17T00:23:00Z

## Investigation State
- **Explored paths**: `Package.swift`, `Sources/AmendCore/`, `.build/checkouts/swift-timecode/`, `Tests/AmendCoreTests/`, `ORIGINAL_REQUEST.md`, `PROJECT.md`
- **Key findings**:
  1. `SwiftTimecodeCore` and `SwiftTimecodeAV` are already integrated in `Package.swift` and provide robust `CMTime <-> Timecode` conversions and drop-frame math.
  2. `Sources/AmendCore/Timeline/` does not exist yet; needs `TimelineClock.swift`, `SMPTERulerFormatter.swift`, `PlayheadSnapper.swift`, `FilmstripGenerator.swift`, and `WaveformExtractor.swift`.
  3. `TimelineClock` must use continuous audio-rate `CMTime` (canonical timescale 600,000) as master clock to prevent cumulative rounding drift across edits.
  4. Playhead scrubbing requires dual-path decoupling (immediate 120Hz UI update + throttled asynchronous AVPlayer seeks) with a formal 4-state transport FSM.
  5. SMPTE drop-frame requires skipping 2 frames per minute (at 29.97 DF) or 4 frames per minute (at 59.94 DF) except on decade minutes.
  6. Magnetic playhead snapping converts 8px threshold to $8 / \text{pixelsPerSecond}$ seconds with dual-threshold hysteresis ($8\text{px}$ acquire / $14\text{px}$ release) and haptic alignment feedback.
- **Unexplored areas**: None for M3 architecture; ready for implementation phase.

## Key Decisions Made
- Chose canonical timescale 600,000 for TimelineClock CMTime arithmetic (lowest common multiple for 24, 25, 30, 48, 50, 60, and fractional rates).
- Defined concrete production Swift API signatures for `TimelineClock`, `SMPTERulerFormatter`, and `PlayheadSnapper`.
- Designed dual-threshold hysteresis ($8\text{px}$ acquire, $14\text{px}$ release) to eliminate scrubbing sticky trap and jitter.

## Artifact Index
- /Users/fady/Dev/amend/.agents/m3_explorer_1_gen2/handoff.md — Final 5-component architectural handoff report
- /Users/fady/Dev/amend/.agents/m3_explorer_1_gen2/progress.md — Execution heartbeat and progress log
- /Users/fady/Dev/amend/.agents/m3_explorer_1_gen2/DISPATCH.md — Dispatch instructions log
