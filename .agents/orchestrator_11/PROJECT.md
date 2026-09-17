# Project: macdub

## Architecture Overview
macdub is a pure native macOS 14.0+ application for screen recording speech editing, narration replacement, and voice cloning that preserves an immutable video timeline with zero synchronization drift.
- **Runtime & Stack**: 100% Native Swift, Core Media (`CMTime`), AVFoundation, Core ML (`FluidAudio` with Parakeet ASR and Silero VAD, PocketTTS), and Accelerate. Zero Python, zero FFmpeg, zero localhost microservices.
- **Target Platform**: macOS 14.0+, Apple Silicon (arm64) with 8GB unified memory budget. Build toolchain: Apple Command Line Tools (`swift build`, `swift test`).
- **Data Flow**:
  1. Source media imported -> Audio tracks inspected (1 track -> advisory badge; >1 -> Track Picker modal) -> APFS copy-on-write clone to `.voicefix` bundle or security-scoped bookmark.
  2. Transcription via Parakeet ASR + Silero VAD (managed by `LocalModelCoordinator`) -> word-timestamped fixed-slot Cues.
  3. Video timeline driven by continuous `CMTime` with SMPTE display ruler (`SwiftTimecode`), async filmstrip (`AVAssetImageGenerator`), and waveform display (`DSWaveformImage`).
  4. Audio editing / synthesis / rewriting operates strictly within immutable slot bounds:
     - Shorter audio: padded with sampled 200–500ms room tone + 10–20ms crossfades.
     - $\le +8\%$ overflow: automatic pitch-preserving `AVAudioUnitTimePitch` compression.
     - $> +8\%$ overflow: gated manual overflow modal ([Rewrite to Fit], [Force Fit], [Split Cue]).
  5. Script rewriting via pluggable `GrammarProvider` with text diff confirmation modal and developer terminology preservation.
  6. Export via non-decoding `AVAssetReaderTrackOutput(outputSettings: nil)` and `AVAssetWriterInput(outputSettings: nil)` remuxing compressed video samples and passthrough audio with rebuilt narration.

---

## Feature Inventory
All features identified during the Phase 0 survey mapped to milestones:

| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | CMTime Master Clock | Audio-rate timeline clock without frame rounding | M3 | R1, ADR 0001 |
| 2 | SMPTE Timecode Ruler | Frame-rate aware timecode display using SwiftTimecode | M3 | R1, SwiftTimecode |
| 3 | Async Video Filmstrip | Background thumbnail generator using AVAssetImageGenerator | M3 | R1 |
| 4 | Audio Waveform Track | Normalized audio peak extraction using DSWaveformImage | M3 | R1, DSWaveformImage |
| 5 | Continuous Draggable Playhead | Frame-accurate video seeking and cue boundary snapping | M3 | R1 |
| 6 | Fixed-Slot Invariant Engine | Guarantee Cue[N+1] boundaries remain identical when Cue[N] edited | M2 | R2, ADR 0001 |
| 7 | Zero-Gap Cue Splitting | Split cue at $t$ into $[t_s, t]$ and $[t, t_e]$ with 0 gap/overlap | M2 | R2 |
| 8 | Boundary Crossfader | 10–20ms crossfading at cue start/end boundaries | M2 | R2, ADR 0005 |
| 9 | Audio Loudness Normalizer | Level matching replacement audio to narration LUFS/RMS | M2 | R2 |
| 10 | Audio Track Inspector | Automatic inspection of all audio tracks in source container | M2 | R3, ADR 0003 |
| 11 | Single-Track Advisory Badge | Auto-assign 1 audio track to Narration with advisory UI badge | M2 | R3, ADR 0003 |
| 12 | Multi-Track Track Picker | Interactive modal designating Narration vs Passthrough tracks | M2 | R3, ADR 0003 |
| 13 | APFS File Cloner | Copy-on-write cloning via FileManager.copyItem into bundle | M1 | R3, ADR 0004 |
| 14 | Security-Scoped Bookmark Fallback | Bookmark reference for cross-volume / non-APFS media | M1 | R3, ADR 0004 |
| 15 | Project Bundle Serializer | Encapsulate project.json, waveforms, thumbs, cue WAVs in .voicefix | M1 | R3, CONTEXT.md |
| 16 | Keychain Credential Vault | Secure storage of API keys via kSecClassGenericPassword | M1 | R3, R5, AC 123 |
| 17 | FluidAudio Parakeet ASR | Core ML speech recognition generating word-timestamped tokens | M4 | R4, ADR 0002 |
| 18 | Silero VAD Engine | Voice Activity Detection for speech and silence segmentation | M4 | R4, ADR 0002 |
| 19 | Interactive Cue Seeking | Clicking cue seeks player to cue.start and selects cue | M3 | R4 |
| 20 | Active Cue Highlighting | Real-time visual tracking and highlighting of playing cue | M3 | R4 |
| 21 | Room-Tone Sampler | Sampling 200–500ms ambient silence slice via VAD | M5 | R5, ADR 0005 |
| 22 | Room-Tone Loop Padding | Residual slot duration filled with looped room tone | M5 | R5, ADR 0005 |
| 23 | Automatic Pitch-Preserving Compressor | Offline AVAudioUnitTimePitch compression for audio $\le +8\%$ | M5 | R5, ADR 0006 |
| 24 | Gated Manual Overflow Controller | Halts automated pipeline for $> +8\%$ overflow with 3 choices | M5 | R5, ADR 0006 |
| 25 | Overflow: Rewrite to Fit | Passes slot duration constraint to LLM to condense text | M5 | R5, ADR 0006, R7 |
| 26 | Overflow: Force Fit | Manual user override forcing extreme pitch-preserved compression | M5 | R5, ADR 0006 |
| 27 | Overflow: Split Cue | User splits cue at playhead to reallocate time across slots | M5 | R5, ADR 0006 |
| 28 | PocketTTS Local Voice Cloning | Pure Swift/CoreML local voice cloning from Reference Voice | M5 | R5, ADR 0002 |
| 29 | ElevenLabs Cloud TTS | Cloud voice synthesis using reference voice / cloned voice | M5 | R5 |
| 30 | Resemble Cloud TTS | Cloud voice synthesis via Resemble AI API | M5 | R5 |
| 31 | Gemini Natural TTS | Prebuilt voices only; strictly forbidden from reference cloning | M5 | R5 |
| 32 | Reference Voice Extractor | Extracts clean 5–15s speech sample for voice cloning | M5 | R5, CONTEXT.md |
| 33 | Compressed Video Passthrough Muxer | Direct AVAssetReader to AVAssetWriter sample buffer piping | M6 | R6, ADR 0008 |
| 34 | Passthrough Audio Remuxer | Remuxes unedited audio tracks directly into output container | M6 | R6, ADR 0008 |
| 35 | Narration Track Rebuilder | Composites cues, room tone, and unedited slices into single track | M6 | R6, ADR 0008 |
| 36 | Presentation Timestamp Sync | Strict preservation of video sample PTS/DTS and total duration | M6 | R6, ADR 0008 |
| 37 | Fast-Path Passthrough Exporter | Optional AVAssetExportSession passthrough shortcut with fallback | M6 | R6, ADR 0008 |
| 38 | Fix Grammar Action | Corrects grammatical errors while preserving developer terminology | M5 | R7 |
| 39 | Make Natural Action | Refines transcript flow while preserving facts and identifiers | M5 | R7 |
| 40 | Restore Original Action | Recovers original transcribed text from originalText field | M5 | R7 |
| 41 | Developer Terminology Filter | AST/regex check ensuring code tokens and URLs are preserved | M5 | R7 |
| 42 | Text Diff Modal | Mandatory visual diff presentation before replacing narration | M5 | R7 |
| 43 | Pluggable GrammarProvider | Protocol supporting local Foundation Models and cloud Gemini API | M5 | R7 |
| 44 | LocalModelCoordinator | Enforces mutual exclusion and task serialization under 8GB RAM | M4 | R8, ADR 0009 |
| 45 | Exclusive Memory Residency | ASR, LLM, and PocketTTS are never in RAM simultaneously | M4 | R8, ADR 0009 |
| 46 | Intermediate Disk Caching | Tokens, waveforms, and synthesized WAVs cached to bundle disk | M1 | R8, ADR 0009 |
| 47 | Deterministic Fixture Generator | Synthetic AVFoundation fixtures (Fixture 1, 2, 3) | E2E_TRACK | ADR 0007 |
| 48 | Bitstream Identity Verifier | SHA256 sample buffer payload identity verification | E2E_TRACK | ADR 0007, ADR 0008 |

---

## Milestones

### Implementation Track

| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | Core Foundation, Storage & Security | Package.swift, MacDubCore target, Core Data Models (Cue, AudioTrackMapping, ProjectBundle, ProjectMetadata, CMTime+Codable), APFS copyItem cloning vs Bookmark fallback, Project bundle serialization (.voicefix/project.json), Keychain Credential Vault (kSecClassGenericPassword), CredentialLeakScanner | none | DONE |
| M2 | Audio Routing & Fixed-Slot Composition Engine | AudioTrackInspector (1 track -> advisory, >1 -> modal), Fixed-slot Composition Engine enforcing immutable CMTime boundaries, Cue splitting with zero gap/overlap, Boundary Crossfader (10–20ms), Loudness Normalizer, Passthrough track preservation | M1 | DONE |
| M3 | Timeline Engine & Visual Presentation | CMTime Master Clock vs SwiftTimecode SMPTE ruler, AVAssetImageGenerator async filmstrip, DSWaveformImage extraction and caching, Interactive Cue track with zoom (pixelsPerSecond), Draggable continuous playhead with frame-accurate video seeking & cue highlighting | M1, M2 | PLANNED |
| M4 | Speech Transcription & Local Model Lifecycle | LocalModelCoordinator actor enforcing serialized lifecycle and exclusive RAM residency under 8GB budget, FluidAudio Parakeet ASR and Silero VAD integration, word-timestamped cue generation, disk caching of tokens and waveforms | M1, M2 | PLANNED |
| M5 | Duration Fitting, Voice Synthesis & Script Rewriting | Room-tone sampler (200–500ms VAD silence) & loop padding, Asymmetric duration fitting (<=8% AVAudioUnitTimePitch offline compression, >8% gated manual overflow with Rewrite/Force/Split), Voice synthesis providers (PocketTTS local cloning, ElevenLabs, Resemble, Gemini non-cloning natural TTS), GrammarProvider rewriting with diff modal & terminology filter | M1, M2, M4 | PLANNED |
| M6 | Compressed-Sample Passthrough Export Pipeline | Deterministic AVAssetReaderTrackOutput to AVAssetWriterInput compressed video sample piping without re-encoding, passthrough audio remuxing, rebuilt narration audio encoding, PTS/DTS preservation, duration matching, optional export session fast-path | M1, M2, M5 | PLANNED |
| M_FINAL | E2E Test Suite Pass & Adversarial Hardening | Phase 1: Pass 100% of E2E test suite (Tiers 1–4) after TEST_READY.md published. Phase 2: Adversarial coverage hardening (Tier 5) with Challenger -> Worker -> Reviewer -> Auditor loop | M1-M6, E2E_TRACK | PLANNED |

### E2E Testing Track (Parallel)

| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| E2E_TRACK | Comprehensive Opaque-Box Test Harness & Fixtures | Synthetic AVFoundation fixtures (Fixture 1 Single-Track, Fixture 2 Multi-Track, Fixture 3 Duration Fitting), Sync Invariant Suite, Sample Payload Identity Test, Memory Lifecycle Test, Security Suite, 4-Tier E2E Suites (40 Tier 1 tests, 40 Tier 2 boundary tests, 7 Tier 3 pairwise suites, 5 Tier 4 workflow scenarios), publish TEST_READY.md | M1 (Package foundation) | PLANNED |

---

## Code Layout

```
/Users/fady/Dev/macdub/
├── Package.swift
├── CONTEXT.md
├── ORIGINAL_REQUEST.md
├── docs/adr/
├── Sources/
│   ├── MacDubCore/
│   │   ├── Models/
│   │   │   ├── CMTime+Codable.swift
│   │   │   ├── CueEditState.swift
│   │   │   ├── Cue.swift
│   │   │   ├── AudioTrackMapping.swift
│   │   │   ├── SourceStorageMode.swift
│   │   │   ├── ProjectMetadata.swift
│   │   │   └── ProjectBundle.swift
│   │   ├── Storage/
│   │   │   ├── APFSCloner.swift
│   │   │   ├── BookmarkManager.swift
│   │   │   ├── ProjectBundleSerializer.swift
│   │   │   ├── KeychainVault.swift
│   │   │   └── CredentialLeakScanner.swift
│   │   ├── Composition/
│   │   │   ├── AudioTrackInspector.swift
│   │   │   ├── SyncInvariantEngine.swift
│   │   │   ├── CueSplitter.swift
│   │   │   ├── BoundaryCrossfader.swift
│   │   │   └── LoudnessNormalizer.swift
│   │   ├── Timeline/
│   │   │   ├── TimelineClock.swift
│   │   │   ├── SMPTERulerFormatter.swift
│   │   │   ├── FilmstripGenerator.swift
│   │   │   └── WaveformExtractor.swift
│   │   ├── ModelLifecycle/
│   │   │   ├── LocalModelCoordinator.swift
│   │   │   ├── ModelResidencyState.swift
│   │   │   └── DiskCacheManager.swift
│   │   ├── Transcription/
│   │   │   ├── SpeechTranscriber.swift
│   │   │   ├── SileroVADEngine.swift
│   │   │   └── CueSegmenter.swift
│   │   ├── DurationFitting/
│   │   │   ├── RoomToneSampler.swift
│   │   │   ├── RoomTonePadder.swift
│   │   │   ├── PitchPreservingCompressor.swift
│   │   │   └── DurationFittingController.swift
│   │   ├── Synthesis/
│   │   │   ├── TTSProvider.swift
│   │   │   ├── PocketTTSLocalCloner.swift
│   │   │   ├── ElevenLabsTTSProvider.swift
│   │   │   ├── ResembleTTSProvider.swift
│   │   │   └── GeminiNaturalTTSProvider.swift
│   │   ├── ScriptRewriting/
│   │   │   ├── GrammarProvider.swift
│   │   │   ├── TerminologyFilter.swift
│   │   │   └── TranscriptHistoryManager.swift
│   │   └── Export/
│   │       ├── PassthroughExportPipeline.swift
│   │       ├── SampleBufferReader.swift
│   │       ├── SampleBufferWriter.swift
│   │       └── NarrationAudioRenderer.swift
│   └── macdub/
│       ├── App/
│       │   └── MacDubApp.swift
│       ├── ViewModels/
│       │   └── ProjectViewModel.swift
│       └── Views/
│           ├── MainWindowView.swift
│           ├── VideoPlayerView.swift
│           ├── TimelineView.swift
│           ├── CueTrackView.swift
│           ├── TrackPickerModal.swift
│           ├── OverflowGatedModal.swift
│           └── TextDiffModal.swift
└── Tests/
    └── MacDubCoreTests/
        ├── Fixtures/
        │   ├── SyntheticFixtureGenerator.swift
        │   ├── Fixture1SingleTrack.swift
        │   ├── Fixture2MultiTrack.swift
        │   └── Fixture3DurationFitting.swift
        ├── Suites/
        │   ├── SyncInvariantTests.swift
        │   ├── SamplePayloadIdentityTests.swift
        │   ├── MemoryLifecycleTests.swift
        │   ├── SecuritySuiteTests.swift
        │   ├── StorageAPFSTests.swift
        │   └── AudioRoutingTests.swift
        └── E2E/
            ├── Tier1FeatureTests.swift
            ├── Tier2BoundaryTests.swift
            ├── Tier3PairwiseTests.swift
            └── Tier4WorkflowTests.swift
```

---

## Interface Contracts

### 1. Storage & Media Management (`Storage` ↔ `Composition`)
```swift
public enum SourceStorageMode: Codable, Equatable, Sendable {
    case cloned(relativePath: String)
    case externalBookmark(bookmarkData: Data, originalPath: String)
}

public struct ProjectMetadata: Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var sourceStorageMode: SourceStorageMode
    public var designatedNarrationTrackID: Int
    public var passthroughTrackIDs: [Int]
    public var totalDuration: CMTime
    public var roomToneRelativePath: String?
}
```

### 2. Timeline & Invariant Models (`Models` ↔ `Composition` ↔ `Timeline`)
```swift
public struct Cue: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timeRange: CMTimeRange // Immutable slot boundaries
    public var text: String
    public var originalText: String
    public var audioWAVRelativePath: String?
    public var editState: CueEditState
    public var overflowDelta: CMTime? // Set when exceeding duration > 8%
}

public enum CueEditState: String, Codable, Equatable, Sendable {
    case original
    case edited
    case synthesized
    case overflowGated
    case forceFitted
}
```

### 3. Model Lifecycle Protocol (`ModelLifecycle` ↔ Subsystems)
```swift
public enum ManagedModelType: Sendable {
    case asr
    case tts
    case llm
}

public protocol LocalModelCoordinating: Actor {
    func executeSerialized<T: Sendable>(model: ManagedModelType, task: @Sendable () async throws -> T) async throws -> T
    func isLoaded(_ model: ManagedModelType) -> Bool
    func evictAll() async
}
```

### 4. Duration Fitting & Audio Processing (`DurationFitting` ↔ `Synthesis`)
```swift
public enum DurationFittingResult: Sendable {
    case naturalPadded(audioBuffer: AVAudioPCMBuffer, roomToneDuration: CMTime)
    case timeCompressed(audioBuffer: AVAudioPCMBuffer, rate: Float) // rate in 1.0...1.08
    case manualOverflowGated(overflowSeconds: Double, suggestedActions: [OverflowAction])
}

public enum OverflowAction: Sendable {
    case rewriteToFit
    case forceFit
    case splitCue(at: CMTime)
}
```

### 5. Pluggable Providers (`Synthesis` & `ScriptRewriting`)
```swift
public protocol TTSProvider: Sendable {
    var providerID: String { get }
    var supportsVoiceCloning: Bool { get } // false for Gemini
    func synthesize(text: String, referenceVoiceURL: URL?) async throws -> AVAudioPCMBuffer
}

public protocol GrammarProvider: Sendable {
    var providerID: String { get }
    func rewrite(text: String, mode: RewriteMode, targetDuration: CMTime?) async throws -> String
}

public enum RewriteMode: Sendable {
    case fixGrammar
    case makeNatural
    case rewriteToFit(maxDuration: CMTime)
}
```

### 6. Compressed Passthrough Export (`Export`)
```swift
public struct ExportConfiguration: Sendable {
    public let sourceMediaURL: URL
    public let destinationURL: URL
    public let designatedNarrationTrackID: Int
    public let passthroughTrackIDs: [Int]
    public let cues: [Cue]
    public let roomToneURL: URL?
}

public protocol PassthroughExporting: Sendable {
    func export(configuration: ExportConfiguration, progress: @Sendable (Double) -> Void) async throws
}
```
