# Task Assignment: m3_explorer_3 (Timeline Presentation, Cue Tracking & UI Binding Explorer)

## Objective
Explore, design, and architect the Interactive Cue Track, Zoom Engine (`pixelsPerSecond`), Active Cue Highlighting, and ViewModel integration for Milestone 3.

## Inputs
- Authoritative User Request: `/Users/fady/Dev/macdub/ORIGINAL_REQUEST.md` (MUST READ FIRST)
- Project Blueprint: `/Users/fady/Dev/macdub/.agents/orchestrator_8/PROJECT.md`
- ADRs: `docs/adr/0001-fixed-sync-invariant.md`
- Existing codebase in `Sources/MacDubCore/` and `Sources/macdub/`

## Key Questions & Scope
1. How should the coordinate system map between continuous `CMTime` and horizontal screen pixels across variable zoom levels (`pixelsPerSecond: Double`, e.g. 50.0 to 500.0 px/s)?
2. How should interactive cue selection and seeking work (clicking a cue in the timeline seeks player to `cue.start` and selects cue in transcript)?
3. How should real-time active cue highlighting be driven during playback with 60fps display link or periodic time observer without stutter or UI main thread lag?
4. How should the ViewModel (`ProjectViewModel`) bind `TimelineClock`, `Cue` collection, and player state together cleanly?

## Output Requirements
Deliver handoff report at `/Users/fady/Dev/macdub/.agents/m3_explorer_3/handoff.md` with:
- Coordinate mapping equations and zoom math.
- View & ViewModel architecture for `TimelineView`, `CueTrackView`, `ProjectViewModel`.
- Unit test strategy and UI integration plan.
Notify caller with send_message upon completion.

## 2026-09-16T21:08:19Z
You are m3_explorer_3, an exploration agent investigating Timeline Presentation, Cue Tracking & UI Binding for Milestone 3.
Your working directory is: /Users/fady/Dev/macdub/.agents/m3_explorer_3
Read your dispatch instructions at: /Users/fady/Dev/macdub/.agents/m3_explorer_3/DISPATCH.md
Read the authoritative user request at: /Users/fady/Dev/macdub/ORIGINAL_REQUEST.md (MANDATORY: read this first)
Read the project blueprint at: /Users/fady/Dev/macdub/.agents/orchestrator_8/PROJECT.md

Investigate and architect interactive cue track presentation, pixelsPerSecond zoom scaling, seeking, and ProjectViewModel binding.
Deliver your handoff report to /Users/fady/Dev/macdub/.agents/m3_explorer_3/handoff.md and notify your parent upon completion.

