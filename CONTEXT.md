# Amend

A native macOS application for developer demo recordings that enables transcript-based speech editing and voice replacement while strictly locking all cue timings to the underlying video.

## Language

**Cue**:
A fixed time-slot in the video containing narration, bounded by immutable start and end timestamps in video time.
_Avoid_: Clip, segment, chunk, region, subtitle

**Narration**:
The spoken vocal audio corresponding to the video, which can be transcribed, edited, or re-synthesized.
_Avoid_: Speech, voiceover, dialogue, audio track

**Sync Invariant**:
The architectural guarantee that cue time boundaries are strictly locked to the video timeline and never shift when narration text or audio changes.
_Avoid_: Fixed sync, time lock, time constraint

**Duration Fitting**:
The process of adapting generated audio to match the fixed duration of a cue via padding, time stretching, or rewriting.
_Avoid_: Retiming, audio warping, sync correction

**Reference Voice**:
A short audio sample of clean speech used to clone the speaker's voice for local or cloud synthesis.
_Avoid_: Voice profile, voice clone sample, training audio, prompt audio

**Room Tone**:
A sampled slice of ambient background sound from the source Narration track used to fill residual gaps in Cues.
_Avoid_: Silence padding, background noise, atmosphere

**Passthrough Track**:
An audio track from the source recording that is passed through untouched without editing or re-encoding.
_Avoid_: Secondary track, unedited track, system track (when referring to passthrough behavior)

**Project Bundle**:
A directory package (`.amend`) referencing the source video and containing project metadata, cached waveforms, thumbnails, and generated cue audio.
_Avoid_: Project file, workspace folder, session, catalog
