# Task Assignment: m2_challenger_4 (Challenger 2 — DSP & Audio Edge Verifier)

## Objective
Empirically stress-test and adversarially challenge Milestone 2's DSP components: `BoundaryCrossfader` and `LoudnessNormalizer`.

## Inputs
- Authoritative User Request: `/Users/fady/Dev/amend/ORIGINAL_REQUEST.md` (MUST READ FIRST)
- Project Blueprint: `/Users/fady/Dev/amend/.agents/orchestrator_8/PROJECT.md`
- Worker Handoff: `/Users/fady/Dev/amend/.agents/m2_worker_2/handoff.md`
- Code under test: `BoundaryCrossfader.swift`, `LoudnessNormalizer.swift`

## Instructions
1. Stress test:
   - Clipping prevention under peak ceiling: feed full-scale (+0 dBFS) signals with positive gain normalization to verify no sample exceeds ceiling (e.g. 0.95).
   - Silent / zero-amplitude buffers, single-sample buffers, or near-Nyquist signals.
   - Equal-power energy conservation across varying window durations (10ms, 15ms, 20ms).
   - NaN, Inf, and denormalized float handling in PCM buffers.
   - Multi-channel audio (mono vs stereo vs 5.1 channel layouts).
2. Deliver handoff report at `/Users/fady/Dev/amend/.agents/m2_challenger_4/handoff.md` with verdict APPROVE or REJECT.
3. Notify caller with send_message upon completion.

## 2026-09-16T20:04:26Z
<USER_REQUEST>
You are m2_challenger_4, an adversarial verification challenger testing Milestone 2's DSP and audio math (BoundaryCrossfader, LoudnessNormalizer).
Your working directory is: /Users/fady/Dev/amend/.agents/m2_challenger_4
Read your dispatch instructions at: /Users/fady/Dev/amend/.agents/m2_challenger_4/DISPATCH.md
Read the authoritative user request at: /Users/fady/Dev/amend/ORIGINAL_REQUEST.md (MANDATORY: read this first)
Read the project blueprint at: /Users/fady/Dev/amend/.agents/orchestrator_8/PROJECT.md
Read the worker handoff at: /Users/fady/Dev/amend/.agents/m2_worker_2/handoff.md

Empirically challenge BoundaryCrossfader and LoudnessNormalizer with adversarial inputs (peak clipping tests, silent buffers, extreme gains, NaN/Inf, equal-power conservation).
Write your handoff report to /Users/fady/Dev/amend/.agents/m2_challenger_4/handoff.md with explicit verdict APPROVE or REJECT.
Send a message to your parent upon completion.
</USER_REQUEST>
