## 2026-09-16T12:52:40Z

You are an Explorer subagent for Milestone 1: Core Foundation, Storage & Security in macdub.
Your assigned working directory is: /Users/fady/Dev/macdub/.agents/m1_explorer_2
Maintain progress.md in your working directory and output your final recommendations to /Users/fady/Dev/macdub/.agents/m1_explorer_2/handoff.md.

Read the authoritative specifications:
- /Users/fady/Dev/macdub/ORIGINAL_REQUEST.md
- /Users/fady/Dev/macdub/.agents/orchestrator_1/PROJECT.md
- /Users/fady/Dev/macdub/CONTEXT.md
- /Users/fady/Dev/macdub/docs/adr/0001-fixed-sync-invariant.md
- /Users/fady/Dev/macdub/docs/adr/0004-apfs-clone-first-project-media-storage.md

Your focus:
Investigate and design the exact data models and storage architecture for Milestone 1:
1. Core domain models:
   - Cue: id (UUID), timeRange (CMTimeRange - immutable slot), text (String), originalText (String), audioWAVRelativePath (String?), editState (CueEditState enum: original, edited, synthesized, overflowGated, forceFitted), overflowDelta (CMTime?).
   - AudioTrackMapping: designatedNarrationTrackID (Int), passthroughTrackIDs ([Int]), isSingleTrackAdvisory (Bool).
   - ProjectMetadata: id (UUID), name (String), sourceStorageMode (enum: cloned(relativePath:) vs externalBookmark(bookmarkData:, originalPath:)), designatedNarrationTrackID (Int), passthroughTrackIDs ([Int]), totalDuration (CMTime), roomToneRelativePath (String?), createdAt (Date), updatedAt (Date).
   - ProjectBundle: layout of .voicefix directory (project.json, source.<ext> or bookmark, waveforms/, thumbnails/, audio/).
2. APFS copyItem cloner & bookmark fallback:
   - URLResourceValues.volumeSupportsFileCloning check.
   - FileManager.copyItem execution for APFS copy-on-write.
   - Security-scoped bookmark creation with URL.bookmarkData(...) and resolution.
   - Serialization to project.json.

Scope boundary:
You are an EXPLORER. Do NOT implement or write source code directly. Produce recommendations for the upcoming Worker.
When finished, write /Users/fady/Dev/macdub/.agents/m1_explorer_2/handoff.md and send a completion message to the caller.
