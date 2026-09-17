# Audio Fixtures & Legal Provenance

This directory contains test audio fixtures used by MacDub's deterministic and acceptance test suites.

## `human_speech_reference.wav`

- **Fixture Filename**: `human_speech_reference.wav`
- **Speaker / Source**: John F. Kennedy, 35th President of the United States. Excerpt from the Presidential Inaugural Address delivered on January 20, 1961 in Washington, D.C. ("...ask not what your country can do for you...").
- **Primary Source**: U.S. National Archives and Records Administration (NARA), digitized and distributed in public open-source ASR test fixtures (e.g. `https://github.com/ggerganov/whisper.cpp/blob/master/samples/jfk.wav`).
- **License / Legal Status**: **Public Domain Worldwide**. Works created by officers or employees of the United States Federal Government as part of their official duties are not subject to copyright protection pursuant to **Title 17, U.S. Code § 105**.
- **Attribution Requirements**: None under Title 17, U.S. Code § 105; documented here for complete provenance, auditability, and legal clarity.
- **Conversion & Formatting**:
  - Source format: 16 kHz mono 16-bit PCM WAV.
  - Slice: 4.5-second time range containing continuous, clear human speech.
  - Resampled format: 24,000 Hz, 1 channel (mono), 16-bit Linear PCM (`pcm_s16le`), RIFF WAV header.
  - Command: `ffmpeg -i jfk.wav -ss 2.0 -to 6.5 -ar 24000 -ac 1 -c:a pcm_s16le human_speech_reference.wav`
- **Usage**: Used as the authentic human speech reference audio for local PocketTTS voice cloning acceptance tests and live neural end-to-end integration tests. Accepts override via `MACDUB_TEST_REFERENCE_VOICE=/path/to/reference.wav`.
