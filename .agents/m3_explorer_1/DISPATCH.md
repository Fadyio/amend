# Task Assignment: m3_explorer_1 (Timeline Clocks & SMPTE Engine Explorer)

## Objective
Explore, design, and architect the Core Media Timeline Clock, SMPTE Timecode Ruler, and Frame-Accurate Seeking / Snapping Engine for Milestone 3.

## Inputs
- Authoritative User Request: `/Users/fady/Dev/macdub/ORIGINAL_REQUEST.md` (MUST READ FIRST)
- Project Blueprint: `/Users/fady/Dev/macdub/.agents/orchestrator_8/PROJECT.md`
- Architecture Decision Records:
  - `docs/adr/0001-fixed-sync-invariant.md`
  - `docs/adr/0002-native-swift-and-coreml-stack.md`
- Existing codebase in `Sources/MacDubCore/` and `Package.swift`

## Key Questions & Scope
1. How should `TimelineClock` be modeled to maintain continuous audio-rate `CMTime` without frame truncation, while supporting play, pause, seek, and rate changes?
2. How should `SMPTERulerFormatter` interface with `SwiftTimecode` to convert `CMTime` to SMPTE timecode string (e.g. `HH:MM:SS:FF`) across various standard frame rates (24, 25, 29.97df, 30, 59.94, 60 fps)?
3. How should playhead snapping to cue boundaries (`cue.start`, `cue.end`) be implemented with configurable snap threshold (e.g. 5–10 pixels converted via `pixelsPerSecond`)?
4. How should the API and interface contracts look for `Sources/MacDubCore/Timeline/TimelineClock.swift` and `SMPTERulerFormatter.swift`?

## Output Requirements
Deliver handoff report at `/Users/fady/Dev/macdub/.agents/m3_explorer_1/handoff.md` with:
- Concrete API design and type definitions.
- Mathematical precision and thread-safety analysis.
- Unit test strategy and edge case checklist.
Notify caller with send_message upon completion.

## 2026-09-16T21:08:19Z
You are m3_explorer_1, an exploration agent investigating Timeline Clocks & SMPTE Engine for Milestone 3.
Your working directory is: /Users/fady/Dev/macdub/.agents/m3_explorer_1
Read your dispatch instructions at: /Users/fady/Dev/macdub/.agents/m3_explorer_1/DISPATCH.md
Read the authoritative user request at: /Users/fady/Dev/macdub/ORIGINAL_REQUEST.md (MANDATORY: read this first)
Read the project blueprint at: /Users/fady/Dev/macdub/.agents/orchestrator_8/PROJECT.md

Investigate and architect TimelineClock and SMPTERulerFormatter with SwiftTimecode integration and boundary snapping.
Deliver your handoff report to /Users/fady/Dev/macdub/.agents/m3_explorer_1/handoff.md and notify your parent upon completion.
