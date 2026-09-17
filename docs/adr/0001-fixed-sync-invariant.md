# Fixed-Slot Synchronization Model

Traditional audio/video transcript editors (such as Descript) ripple-edit the timeline when text is added or removed, which alters video length and breaks screen action synchronization. We decided that video timestamps are strictly immutable (`CMTime` / `CMTimeRange`), meaning cues never shift when narration is edited. Generated audio must always be fitted to the slot (via padding, time-stretching, or rewriting) to preserve exact video alignment and allow instant passthrough mux export.
