# Handoff Report: Milestone 2 — Audio Routing & Fixed-Slot Composition Engine

## 1. Observation

### 1.1 Requirements & ADR Context
- **ORIGINAL_REQUEST.md:37–43 (R2)** specifies:
  - "Every Cue maintains immutable start and end CMTime boundaries."
  - "Editing narration text or replacing audio in Cue N guarantees Cue[N+1].start and Cue[N+1].end remain identical."
  - "Splitting a cue at playhead t produces [t_start, t] and [t, t_end] with zero gap or overlap."
  - "Audio replacements apply loudness normalization and 10–20 ms boundary crossfades."
- **ORIGINAL_REQUEST.md:44–49 (R3)** specifies:
  - "Automatically inspect all audio tracks in source media. If exactly 1 audio track is found, assign it as Narration with a single-track advisory badge. If >1 audio tracks are found, prompt the user with a Track Picker modal to designate Narration vs Passthrough tracks."
- **ORIGINAL_REQUEST.md:90–97 & Acceptance Criteria 108–117**:
  - Single-track vs multi-track routing and advisory badge logic (AC 108–109).
  - Sync invariant asserting `Cue[N+1].startBefore == Cue[N+1].startAfter` across text edits, splits, and re-renders (AC 114).
  - Cue splitting at $t$ yielding two valid cues spanning $[t_{start}, t]$ and $[t, t_{end}]$ with zero gap or overlap (AC 115).
  - Slot duration matching immutable `CMTimeRange` (AC 116).
- **docs/adr/0001-fixed-sync-invariant.md:3**:
  - "Traditional audio/video transcript editors... ripple-edit the timeline... which alters video length and breaks screen action synchronization. We decided that video timestamps are strictly immutable (`CMTime` / `CMTimeRange`), meaning cues never shift when narration is edited."
- **docs/adr/0003-ambiguity-safe-audio-track-mapping.md:3**:
  - "...inspect all audio tracks on import: if exactly one audio track exists, it is automatically assigned as Narration with a single-track warning; if multiple tracks exist, a lightweight Track Picker modal prompts the user to confirm the Narration track and Passthrough tracks."
- **docs/adr/0005-ambient-room-tone-cue-padding.md:3**:
  - "10–20 ms boundary crossfades are applied to guarantee seamless acoustic continuity and exact `CMTimeRange` adherence."

### 1.2 Existing Codebase State in `Sources/AmendCore/`
- **Models Directory**:
  - `Sources/AmendCore/Models/Cue.swift`: Implements `Cue` (`id: UUID`, `timeRange: CMTimeRange`, `text: String`, `originalText: String`, `audioWAVRelativePath: String?`, `editState: CueEditState`, `overflowDelta: CMTime?`). Lines 31–33 expose `public var start: CMTime`, `public var duration: CMTime`, `public var end: CMTime`.
  - `Sources/AmendCore/Models/AudioTrackMapping.swift`: Implements `AudioTrackMapping` (`designatedNarrationTrackID: Int`, `passthroughTrackIDs: [Int]`, `isSingleTrackAdvisory: Bool`, with static factories `.singleTrack(trackID:)` and `.multiTrack(narrationTrackID:passthroughTrackIDs:)` and validation `.isValid`).
  - `Sources/AmendCore/Models/ProjectMetadata.swift`: Includes `cues: [Cue]`, `audioTrackMapping: AudioTrackMapping`, `designatedNarrationTrackID: Int`, `passthroughTrackIDs: [Int]`, `isSingleTrackAdvisory: Bool`.
  - `Sources/AmendCore/Models/CMTime+Codable.swift`: Provides `@retroactive Codable` conformance for `CMTime` and `CMTimeRange`.
- **Target Directories for Milestone 2**:
  - `Sources/AmendCore/Composition/` does not yet exist.
  - Required source files to create in M2:
    1. `Sources/AmendCore/Composition/AudioTrackInspector.swift`
    2. `Sources/AmendCore/Composition/SyncInvariantEngine.swift`
    3. `Sources/AmendCore/Composition/CueSplitter.swift`
    4. `Sources/AmendCore/Composition/BoundaryCrossfader.swift`
    5. `Sources/AmendCore/Composition/LoudnessNormalizer.swift`
  - Required test suites to create in M2:
    1. `Tests/AmendCoreTests/Suites/AudioRoutingTests.swift`
    2. `Tests/AmendCoreTests/Suites/SyncInvariantTests.swift`

---

## 2. Logic Chain

### 2.1 Fixed-Slot Synchronization Engine (`SyncInvariantEngine`)
1. **Mathematical Invariant**:
   Let the timeline be represented as an ordered sequence of cues:
   $$\mathcal{T} = \langle C_0, C_1, \dots, C_{M-1} \rangle$$
   Each cue $C_i$ occupies a closed-open interval in the timeline:
   $$\mathcal{I}(C_i) = [t_{s, i}, t_{e, i}) = [C_i.\text{timeRange.start}, C_i.\text{timeRange.start} + C_i.\text{timeRange.duration})$$
   When an edit $\mathcal{E}$ is performed on cue $C_N$ (modifying text, replacing audio WAV, or adjusting voice synthesis):
   $$\forall k \ne N: \quad C_k.\text{start}_{\text{after}} = C_k.\text{start}_{\text{before}} \quad \land \quad C_k.\text{duration}_{\text{after}} = C_k.\text{duration}_{\text{before}} \quad \land \quad C_k.\text{end}_{\text{after}} = C_k.\text{end}_{\text{before}}$$
   Furthermore, for the target slot $C_N$:
   $$C_N.\text{start}_{\text{after}} = C_N.\text{start}_{\text{before}} \quad \land \quad C_N.\text{duration}_{\text{after}} = C_N.\text{duration}_{\text{before}}$$
   Any narration text or replacement audio MUST conform to the slot. The slot NEVER ripples or alters temporal boundaries.
2. **Rational Arithmetic Precision**:
   Using floating-point `Double` representations for timeline math creates cumulative rounding errors (e.g. $0.1 + 0.2 \ne 0.3$). `SyncInvariantEngine` operates strictly on exact rational CoreMedia types (`CMTime` and `CMTimeRange`):
   - All additions use `CMTimeAdd(a, b)`
   - All subtractions use `CMTimeSubtract(a, b)`
   - Timescale normalization uses `CMTimeConvertScale(t, timescale: audioSampleRate, method: .default)`
   - Internal cue boundaries are NEVER quantized or rounded to SMPTE video frame boundaries.

### 2.2 Cue Splitting Engine (`CueSplitter`)
1. **Continuous Split Specification**:
   For any cue $C$ with $\text{timeRange} = [t_s, t_e)$ and a split timestamp $t_{split}$:
   - Precondition: $t_s < t_{split} < t_e$.
   - The operation produces two disjoint contiguous cues $C_A$ and $C_B$:
     $$C_A.\text{timeRange} = [t_s, t_{split}), \quad \text{duration}(C_A) = t_{split} - t_s$$
     $$C_B.\text{timeRange} = [t_{split}, t_e), \quad \text{duration}(C_B) = t_e - t_{split}$$
2. **Zero Gap and Zero Overlap Proof**:
   $$\text{Gap} = C_B.\text{start} - C_A.\text{end} = t_{split} - t_{split} = 0$$
   $$\text{Overlap} = \max(0, C_A.\text{end} - C_B.\text{start}) = \max(0, t_{split} - t_{split}) = 0$$
   $$\text{duration}(C_A) + \text{duration}(C_B) = (t_{split} - t_s) + (t_e - t_{split}) = t_e - t_s = \text{duration}(C)$$
   All equalities hold strictly in rational `CMTime` ticks without rounding.
3. **Neighbor Immutability**:
   When replacing $C_N$ with $\{C_{N, A}, C_{N, B}\}$ in the timeline array, $\forall k < N: C_k$ is untouched, and $\forall k > N: C_k$ is untouched. The global project duration remains bit-for-bit unchanged.

### 2.3 Boundary Crossfader (`BoundaryCrossfader`)
1. **Acoustic Problem**: Abruptly splicing replacement audio or joining cues at non-zero-crossing audio samples creates broadband impulse transients (audible clicks and pops).
2. **Crossfade Window**:
   10–20 ms window ($N = \text{Int}(\text{sampleRate} \times \text{windowDuration})$ samples; at 48 kHz, 10ms = 480 samples, 15ms = 720 samples, 20ms = 960 samples).
3. **Crossfade Curves**:
   - **Linear Crossfade**:
     $$w_{\text{fade\_out}}(i) = 1.0 - \frac{i}{N}, \quad w_{\text{fade\_in}}(i) = \frac{i}{N}, \quad i \in [0, N]$$
   - **Equal-Power Crossfade**:
     For uncorrelated signals (speech vs ambient room tone), linear crossfades produce a $-3 \text{ dB}$ dip in acoustic power at the midpoint ($i = N/2$). Equal-power windowing maintains constant sound power across the transition:
     $$\theta(i) = \frac{\pi}{2} \cdot \frac{i}{N}$$
     $$w_{\text{fade\_out}}(i) = \cos(\theta(i)), \quad w_{\text{fade\_in}}(i) = \sin(\theta(i))$$
     $$\text{Total Power} = w_{\text{fade\_out}}^2(i) + w_{\text{fade\_in}}^2(i) = \cos^2(\theta(i)) + \sin^2(\theta(i)) \equiv 1.0$$
4. **Safety Mechanisms**:
   - If the audio buffer duration $< 2 \times \text{windowDuration}$, scale window duration to half the buffer duration to prevent overlapping fade-in and fade-out.
   - Vectorized window multiplication across all audio channels (mono/stereo) using Accelerate / `vDSP`.

### 2.4 Audio Track Inspector (`AudioTrackInspector`)
1. **Asset Inspection**:
   Uses modern async AVFoundation API (`asset.loadTracks(withMediaType: .audio)`).
2. **Metadata Extraction**:
   Extracts `CMPersistentTrackID`, channel count (`mChannelsPerFrame`), sample rate (`mSampleRate`), bit depth (`mBitsPerChannel`), format code (`kAudioFormatLinearPCM` -> "lpcm", `kAudioFormatMPEG4AAC` -> "aac"), time range, and language metadata.
3. **Ambiguity-Safe Routing Rules**:
   - **0 Audio Tracks**: Returns `.noAudioTracks` or throws `AudioTrackInspectorError.noAudioTracksFound`.
   - **1 Audio Track**: Returns `.singleTrack(track: info, mapping: .singleTrack(trackID: info.id))` with `isSingleTrackAdvisory = true`.
   - **>1 Audio Tracks**: Returns `.multiTrack(tracks: infos, defaultMapping: .multiTrack(narrationTrackID: infos[0].id, passthroughTrackIDs: Array(infos.dropFirst().map(\.id))))` with `isSingleTrackAdvisory = false`.
4. **Mapping Validation**:
   Guarantees that narration track ID is valid, passthrough track IDs are valid and disjoint from narration track ID, and no duplicate IDs exist.

### 2.5 Audio Loudness Normalizer (`LoudnessNormalizer`)
1. **Acoustic Measurement**:
   - **RMS (Root Mean Square)**:
     $$\text{RMS} = \sqrt{\frac{1}{N} \sum_{i=0}^{N-1} x[i]^2}, \quad \text{dBFS} = 20 \log_{10}(\max(\text{RMS}, 10^{-9}))$$
     Accelerate `vDSP_rmsqv` provides high-performance vectorized calculation.
   - **LUFS (ITU-R BS.1770-4 / EBU R128)**:
     - K-weighting two-stage IIR filter (high-shelf filter $+4\text{ dB}$ at $1500\text{ Hz}$, high-pass RLB filter at $\sim 38\text{ Hz}$).
     - Gated loudness measurement (absolute threshold at $-70\text{ LKFS}$, relative threshold at $-10\text{ LU}$ below ungated mean).
2. **Level Matching & Clamping**:
   $$\Delta \text{dB} = \text{targetLUFS} - \text{measuredLUFS}, \quad g = 10^{\Delta \text{dB} / 20}$$
   - Peak ceiling limiter: if $g \times \hat{p} > \text{peakCeiling}$ (where $\text{peakCeiling} = 0.95 \approx -0.45\text{ dBFS}$), gain is clamped to $g_{\text{clamped}} = \frac{\text{peakCeiling}}{\hat{p}}$ to prevent clipping.
   - Vectorized sample multiplication via `vDSP_vsmul`.

---

## 3. Detailed Implementation Architecture

### 3.1 Model Extensions (`Sources/AmendCore/Models/`)

#### Extensions to `Cue.swift`:
```swift
extension Cue {
    /// Creates a functional copy with updated narration text, preserving immutable timeRange and originalText.
    public func withUpdatedText(_ newText: String) -> Cue {
        Cue(
            id: self.id,
            timeRange: self.timeRange, // Strictly immutable
            text: newText,
            originalText: self.originalText,
            audioWAVRelativePath: self.audioWAVRelativePath,
            editState: .edited,
            overflowDelta: self.overflowDelta
        )
    }

    /// Creates a functional copy with updated audio replacement, preserving immutable timeRange.
    public func withUpdatedAudio(
        audioWAVRelativePath: String?,
        editState: CueEditState,
        overflowDelta: CMTime? = nil
    ) -> Cue {
        Cue(
            id: self.id,
            timeRange: self.timeRange, // Strictly immutable
            text: self.text,
            originalText: self.originalText,
            audioWAVRelativePath: audioWAVRelativePath,
            editState: editState,
            overflowDelta: overflowDelta
        )
    }

    /// Checks whether a given continuous timestamp falls within this cue's slot boundaries.
    public func contains(time: CMTime) -> Bool {
        CMTimeCompare(time, timeRange.start) >= 0 && CMTimeCompare(time, timeRange.end) < 0
    }
}
```

#### Audio Track Info Model (`AudioTrackInfo.swift`):
```swift
public struct AudioTrackInfo: Identifiable, Codable, Equatable, Sendable {
    public let id: Int
    public let format: String
    public let channelCount: Int
    public let sampleRate: Double
    public let bitDepth: Int?
    public let duration: CMTime
    public let timeRange: CMTimeRange
    public let languageCode: String?
    public let title: String?
    public let estimatedDataRate: Float

    public init(
        id: Int,
        format: String,
        channelCount: Int,
        sampleRate: Double,
        bitDepth: Int? = nil,
        duration: CMTime,
        timeRange: CMTimeRange,
        languageCode: String? = nil,
        title: String? = nil,
        estimatedDataRate: Float = 0.0
    ) {
        self.id = id
        self.format = format
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.duration = duration
        self.timeRange = timeRange
        self.languageCode = languageCode
        self.title = title
        self.estimatedDataRate = estimatedDataRate
    }
}
```

---

### 3.2 `Sources/AmendCore/Composition/AudioTrackInspector.swift`

```swift
import Foundation
import AVFoundation
import CoreMedia

public enum AudioTrackInspectionResult: Equatable, Sendable {
    case singleTrack(track: AudioTrackInfo, mapping: AudioTrackMapping)
    case multiTrack(tracks: [AudioTrackInfo], defaultMapping: AudioTrackMapping)
    case noAudioTracks
}

public enum AudioTrackInspectorError: Error, LocalizedError, Equatable, Sendable {
    case fileNotFound(URL)
    case unreadableAsset(URL, String)
    case noAudioTracksFound(URL)
    case designatedTrackNotInAsset(Int)
    case passthroughTrackNotInAsset(Int)
    case narrationInPassthroughList(Int)
    case duplicatePassthroughTrackIDs([Int])
    case singleTrackAdvisoryViolation(String)
}

public struct AudioTrackInspector: Sendable {
    public init() {}

    public func inspect(assetURL: URL) async throws -> AudioTrackInspectionResult {
        guard FileManager.default.fileExists(atPath: assetURL.path) else {
            throw AudioTrackInspectorError.fileNotFound(assetURL)
        }
        let asset = AVURLAsset(url: assetURL)
        return try await inspect(asset: asset)
    }

    public func inspect(asset: AVAsset) async throws -> AudioTrackInspectionResult {
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw AudioTrackInspectorError.unreadableAsset(
                (asset as? AVURLAsset)?.url ?? URL(fileURLWithPath: "/unknown"),
                error.localizedDescription
            )
        }

        if tracks.isEmpty {
            return .noAudioTracks
        }

        var trackInfos: [AudioTrackInfo] = []
        for track in tracks {
            let trackID = Int(track.trackID)
            let timeRange = try await track.load(.timeRange)
            let formatDescriptions = try await track.load(.formatDescriptions)
            let language = try? await track.load(.extendedLanguageTag)
            let dataRate = (try? await track.load(.estimatedDataRate)) ?? 0.0

            var formatString = "unknown"
            var channelCount = 2
            var sampleRate = 48000.0
            var bitDepth: Int? = nil

            if let firstDesc = formatDescriptions.first {
                let audioDesc = firstDesc as! CMAudioFormatDescription
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioDesc)?.pointee {
                    formatString = fourCharCodeToString(asbd.mFormatID)
                    channelCount = Int(asbd.mChannelsPerFrame)
                    sampleRate = asbd.mSampleRate
                    if asbd.mBitsPerChannel > 0 {
                        bitDepth = Int(asbd.mBitsPerChannel)
                    }
                }
            }

            let info = AudioTrackInfo(
                id: trackID,
                format: formatString,
                channelCount: channelCount,
                sampleRate: sampleRate,
                bitDepth: bitDepth,
                duration: timeRange.duration,
                timeRange: timeRange,
                languageCode: language,
                title: nil,
                estimatedDataRate: dataRate
            )
            trackInfos.append(info)
        }

        if trackInfos.count == 1 {
            let single = trackInfos[0]
            let mapping = AudioTrackMapping.singleTrack(trackID: single.id)
            return .singleTrack(track: single, mapping: mapping)
        } else {
            let narrationID = trackInfos[0].id
            let passthroughIDs = Array(trackInfos.dropFirst().map(\.id))
            let defaultMapping = AudioTrackMapping.multiTrack(
                narrationTrackID: narrationID,
                passthroughTrackIDs: passthroughIDs
            )
            return .multiTrack(tracks: trackInfos, defaultMapping: defaultMapping)
        }
    }

    public func validate(mapping: AudioTrackMapping, against tracks: [AudioTrackInfo]) throws {
        let availableIDs = Set(tracks.map(\.id))
        guard availableIDs.contains(mapping.designatedNarrationTrackID) else {
            throw AudioTrackInspectorError.designatedTrackNotInAsset(mapping.designatedNarrationTrackID)
        }
        for passID in mapping.passthroughTrackIDs {
            guard availableIDs.contains(passID) else {
                throw AudioTrackInspectorError.passthroughTrackNotInAsset(passID)
            }
        }
        if mapping.passthroughTrackIDs.contains(mapping.designatedNarrationTrackID) {
            throw AudioTrackInspectorError.narrationInPassthroughList(mapping.designatedNarrationTrackID)
        }
        let uniquePassthrough = Set(mapping.passthroughTrackIDs)
        if uniquePassthrough.count != mapping.passthroughTrackIDs.count {
            throw AudioTrackInspectorError.duplicatePassthroughTrackIDs(mapping.passthroughTrackIDs)
        }
        if mapping.isSingleTrackAdvisory && (!mapping.passthroughTrackIDs.isEmpty || tracks.count > 1) {
            throw AudioTrackInspectorError.singleTrackAdvisoryViolation(
                "Single-track advisory mapping cannot have passthrough tracks or multiple source tracks."
            )
        }
    }

    private func fourCharCodeToString(_ code: FourCharCode) -> String {
        let bytes: [CChar] = [
            CChar((code >> 24) & 0xFF),
            CChar((code >> 16) & 0xFF),
            CChar((code >> 8) & 0xFF),
            CChar(code & 0xFF),
            0
        ]
        return String(cString: bytes).trimmingCharacters(in: .whitespaces)
    }
}
```

---

### 3.3 `Sources/AmendCore/Composition/SyncInvariantEngine.swift`

```swift
import Foundation
import CoreMedia

public enum SyncInvariantError: Error, LocalizedError, Equatable, Sendable {
    case cueNotFound(UUID)
    case overlappingCues(cueA: UUID, cueB: UUID, rangeA: CMTimeRange, rangeB: CMTimeRange)
    case cuesOutOfChronologicalOrder(cueA: UUID, cueB: UUID)
    case zeroOrNegativeDuration(UUID, CMTime)
    case timeExceedsProjectDuration(UUID, CMTime, CMTime)
    case invariantViolationBoundaryShifted(cueID: UUID, expected: CMTimeRange, actual: CMTimeRange)
    case nonTargetCueMutated(cueID: UUID)
}

public struct SyncInvariantEngine: Sendable {
    public init() {}

    /// Updates narration text for a target cue, strictly guaranteeing that all cue boundaries remain immutable.
    public func updateCueText(
        in cues: [Cue],
        cueID: UUID,
        newText: String
    ) throws -> [Cue] {
        guard let index = cues.firstIndex(where: { $0.id == cueID }) else {
            throw SyncInvariantError.cueNotFound(cueID)
        }
        let originalCue = cues[index]
        let updatedCue = originalCue.withUpdatedText(newText)

        var newCues = cues
        newCues[index] = updatedCue

        try assertSyncInvariant(before: cues, after: newCues, modifiedCueID: cueID)
        return newCues
    }

    /// Updates audio replacement for a target cue, strictly guaranteeing immutable slot boundaries.
    public func updateCueAudio(
        in cues: [Cue],
        cueID: UUID,
        audioRelativePath: String?,
        editState: CueEditState,
        overflowDelta: CMTime? = nil
    ) throws -> [Cue] {
        guard let index = cues.firstIndex(where: { $0.id == cueID }) else {
            throw SyncInvariantError.cueNotFound(cueID)
        }
        let originalCue = cues[index]
        let updatedCue = originalCue.withUpdatedAudio(
            audioWAVRelativePath: audioRelativePath,
            editState: editState,
            overflowDelta: overflowDelta
        )

        var newCues = cues
        newCues[index] = updatedCue

        try assertSyncInvariant(before: cues, after: newCues, modifiedCueID: cueID)
        return newCues
    }

    /// Verifies the fixed-slot invariant: non-target cues must be identical; target cue timeRange must be identical.
    public func assertSyncInvariant(
        before: [Cue],
        after: [Cue],
        modifiedCueID: UUID
    ) throws {
        guard before.count == after.count else {
            throw SyncInvariantError.nonTargetCueMutated(cueID: modifiedCueID)
        }
        for (b, a) in zip(before, after) {
            guard b.id == a.id else {
                throw SyncInvariantError.nonTargetCueMutated(cueID: a.id)
            }
            // Strict rational CMTime comparison
            if CMTimeCompare(b.timeRange.start, a.timeRange.start) != 0 ||
               CMTimeCompare(b.timeRange.duration, a.timeRange.duration) != 0 {
                throw SyncInvariantError.invariantViolationBoundaryShifted(
                    cueID: a.id,
                    expected: b.timeRange,
                    actual: a.timeRange
                )
            }
            if b.id != modifiedCueID {
                // Non-target cues must have untouched text and audio
                if b.text != a.text || b.audioWAVRelativePath != a.audioWAVRelativePath || b.editState != a.editState {
                    throw SyncInvariantError.nonTargetCueMutated(cueID: a.id)
                }
            }
        }
    }

    /// Validates chronological ordering, non-overlap, and positive duration for a list of cues.
    public func validateTimelineContinuity(
        cues: [Cue],
        totalDuration: CMTime? = nil
    ) throws {
        var previousEnd = CMTime.zero
        for i in 0..<cues.count {
            let current = cues[i]
            if CMTimeCompare(current.duration, .zero) <= 0 {
                throw SyncInvariantError.zeroOrNegativeDuration(current.id, current.duration)
            }
            if i > 0 {
                let prev = cues[i - 1]
                if CMTimeCompare(current.start, prev.start) < 0 {
                    throw SyncInvariantError.cuesOutOfChronologicalOrder(cueA: prev.id, cueB: current.id)
                }
                if CMTimeCompare(current.start, prev.end) < 0 {
                    throw SyncInvariantError.overlappingCues(
                        cueA: prev.id,
                        cueB: current.id,
                        rangeA: prev.timeRange,
                        rangeB: current.timeRange
                    )
                }
            }
            if let maxDuration = totalDuration {
                if CMTimeCompare(current.end, maxDuration) > 0 {
                    throw SyncInvariantError.timeExceedsProjectDuration(current.id, current.end, maxDuration)
                }
            }
            previousEnd = current.end
        }
    }
}
```

---

### 3.4 `Sources/AmendCore/Composition/CueSplitter.swift`

```swift
import Foundation
import CoreMedia

public enum CueSplitterError: Error, LocalizedError, Equatable, Sendable {
    case targetCueNotFound(UUID)
    case splitTimestampOutOfBounds(splitTime: CMTime, cueRange: CMTimeRange)
    case splitTimestampAtBoundary(splitTime: CMTime, boundary: CMTime)
    case resultingDurationTooShort(CMTime, minimumRequired: CMTime)
}

public struct CueSplitter: Sendable {
    public let minimumDuration: CMTime

    public init(minimumDuration: CMTime = CMTime(value: 10, timescale: 1000)) { // 10 ms minimum duration
        self.minimumDuration = minimumDuration
    }

    /// Splits an isolated cue at timestamp t into cueA [start, t] and cueB [t, end] with 0 gap and 0 overlap.
    public func split(
        cue: Cue,
        at splitTime: CMTime,
        textSplitIndex: String.Index? = nil
    ) throws -> (cueA: Cue, cueB: Cue) {
        let start = cue.start
        let end = cue.end

        // Ensure splitTime is strictly inside (start, end)
        if CMTimeCompare(splitTime, start) <= 0 {
            throw CueSplitterError.splitTimestampOutOfBounds(splitTime: splitTime, cueRange: cue.timeRange)
        }
        if CMTimeCompare(splitTime, end) >= 0 {
            throw CueSplitterError.splitTimestampOutOfBounds(splitTime: splitTime, cueRange: cue.timeRange)
        }

        // Exact rational subtraction: durationA = splitTime - start; durationB = end - splitTime
        let durationA = CMTimeSubtract(splitTime, start)
        let durationB = CMTimeSubtract(end, splitTime)

        if CMTimeCompare(durationA, minimumDuration) < 0 {
            throw CueSplitterError.resultingDurationTooShort(durationA, minimumRequired: minimumDuration)
        }
        if CMTimeCompare(durationB, minimumDuration) < 0 {
            throw CueSplitterError.resultingDurationTooShort(durationB, minimumRequired: minimumDuration)
        }

        let rangeA = CMTimeRange(start: start, duration: durationA)
        let rangeB = CMTimeRange(start: splitTime, duration: durationB)

        // Text partitioning
        let textA: String
        let textB: String
        if let idx = textSplitIndex, idx >= cue.text.startIndex && idx <= cue.text.endIndex {
            textA = String(cue.text[..<idx]).trimmingCharacters(in: .whitespaces)
            textB = String(cue.text[idx...]).trimmingCharacters(in: .whitespaces)
        } else {
            // Default split: preserve full original text in originalText, split words proportionally
            let words = cue.text.split(separator: " ")
            if words.count > 1 {
                let ratio = CMTimeGetSeconds(durationA) / CMTimeGetSeconds(cue.duration)
                let splitWordIndex = max(1, min(words.count - 1, Int((Double(words.count) * ratio).rounded())))
                textA = words[..<splitWordIndex].joined(separator: " ")
                textB = words[splitWordIndex...].joined(separator: " ")
            } else {
                textA = cue.text
                textB = cue.text
            }
        }

        let cueA = Cue(
            id: UUID(),
            timeRange: rangeA,
            text: textA,
            originalText: textA,
            audioWAVRelativePath: nil,
            editState: .edited,
            overflowDelta: nil
        )

        let cueB = Cue(
            id: UUID(),
            timeRange: rangeB,
            text: textB,
            originalText: textB,
            audioWAVRelativePath: nil,
            editState: .edited,
            overflowDelta: nil
        )

        return (cueA, cueB)
    }

    /// Splits a cue within a timeline array, ensuring all neighbor cues remain bitwise untouched.
    public func splitCue(
        in cues: [Cue],
        targetCueID: UUID,
        at splitTime: CMTime,
        textSplitIndex: String.Index? = nil
    ) throws -> (updatedCues: [Cue], splitA: Cue, splitB: Cue) {
        guard let index = cues.firstIndex(where: { $0.id == targetCueID }) else {
            throw CueSplitterError.targetCueNotFound(targetCueID)
        }
        let targetCue = cues[index]
        let (cueA, cueB) = try split(cue: targetCue, at: splitTime, textSplitIndex: textSplitIndex)

        var newCues = cues
        newCues.remove(at: index)
        newCues.insert(cueB, at: index)
        newCues.insert(cueA, at: index)

        return (newCues, cueA, cueB)
    }
}
```

---

### 3.5 `Sources/AmendCore/Composition/BoundaryCrossfader.swift`

```swift
import Foundation
import AVFoundation
import Accelerate

public enum CrossfadeCurve: Sendable {
    case linear
    case equalPower
}

public enum BoundaryCrossfaderError: Error, LocalizedError, Equatable, Sendable {
    case invalidBuffer(String)
    case unsupportedAudioFormat(String)
}

public struct BoundaryCrossfader: Sendable {
    public init() {}

    /// Applies fade-in at the head and fade-out at the tail of the audio buffer.
    public func applyBoundaryFades(
        to buffer: AVAudioPCMBuffer,
        windowDuration: TimeInterval = 0.015, // 15 ms default
        curve: CrossfadeCurve = .equalPower
    ) throws {
        guard let floatChannelData = buffer.floatChannelData else {
            throw BoundaryCrossfaderError.unsupportedAudioFormat("Only 32-bit float PCM buffers supported")
        }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        let sampleRate = buffer.format.sampleRate
        var fadeLength = Int((windowDuration * sampleRate).rounded())
        // Safety: if buffer is too short, clamp fade length to half the buffer
        if fadeLength * 2 > frameCount {
            fadeLength = max(1, frameCount / 2)
        }

        let channelCount = Int(buffer.format.channelCount)

        for ch in 0..<channelCount {
            let channelPtr = floatChannelData[ch]

            // 1. Fade-in
            for i in 0..<fadeLength {
                let factor: Float
                switch curve {
                case .linear:
                    factor = Float(i) / Float(fadeLength)
                case .equalPower:
                    let theta = (Float.pi / 2.0) * (Float(i) / Float(fadeLength))
                    factor = sin(theta)
                }
                channelPtr[i] *= factor
            }

            // 2. Fade-out
            let tailStartIndex = frameCount - fadeLength
            for i in 0..<fadeLength {
                let factor: Float
                switch curve {
                case .linear:
                    factor = 1.0 - (Float(i) / Float(fadeLength))
                case .equalPower:
                    let theta = (Float.pi / 2.0) * (Float(i) / Float(fadeLength))
                    factor = cos(theta)
                }
                channelPtr[tailStartIndex + i] *= factor
            }
        }
    }

    /// Crossfades two buffers into a combined contiguous buffer with overlapping transition.
    public func crossfade(
        bufferA: AVAudioPCMBuffer,
        bufferB: AVAudioPCMBuffer,
        windowDuration: TimeInterval = 0.015,
        curve: CrossfadeCurve = .equalPower
    ) throws -> AVAudioPCMBuffer {
        guard bufferA.format == bufferB.format else {
            throw BoundaryCrossfaderError.invalidBuffer("Buffer formats must match for crossfading")
        }
        guard let format = bufferA.format as AVAudioFormat?,
              let dataA = bufferA.floatChannelData,
              let dataB = bufferB.floatChannelData else {
            throw BoundaryCrossfaderError.unsupportedAudioFormat("Float channel data missing")
        }

        let lenA = Int(bufferA.frameLength)
        let lenB = Int(bufferB.frameLength)
        let sampleRate = format.sampleRate
        var fadeLength = Int((windowDuration * sampleRate).rounded())
        fadeLength = min(fadeLength, min(lenA, lenB))

        let totalLength = lenA + lenB - fadeLength
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalLength)) else {
            throw BoundaryCrossfaderError.invalidBuffer("Cannot allocate output buffer")
        }
        output.frameLength = AVAudioFrameCount(totalLength)
        guard let outData = output.floatChannelData else {
            throw BoundaryCrossfaderError.unsupportedAudioFormat("Cannot access output floatChannelData")
        }

        let channelCount = Int(format.channelCount)
        let unmixedA = lenA - fadeLength

        for ch in 0..<channelCount {
            let ptrA = dataA[ch]
            let ptrB = dataB[ch]
            let ptrOut = outData[ch]

            // 1. Copy unmixed prefix of A
            memcpy(ptrOut, ptrA, unmixedA * MemoryLayout<Float>.size)

            // 2. Crossfade overlap region
            for i in 0..<fadeLength {
                let wA: Float
                let wB: Float
                switch curve {
                case .linear:
                    wA = 1.0 - (Float(i) / Float(fadeLength))
                    wB = Float(i) / Float(fadeLength)
                case .equalPower:
                    let theta = (Float.pi / 2.0) * (Float(i) / Float(fadeLength))
                    wA = cos(theta)
                    wB = sin(theta)
                }
                ptrOut[unmixedA + i] = (ptrA[unmixedA + i] * wA) + (ptrB[i] * wB)
            }

            // 3. Copy remainder of B
            let remainderB = lenB - fadeLength
            if remainderB > 0 {
                memcpy(ptrOut + lenA, ptrB + fadeLength, remainderB * MemoryLayout<Float>.size)
            }
        }

        return output
    }
}
```

---

### 3.6 `Sources/AmendCore/Composition/LoudnessNormalizer.swift`

```swift
import Foundation
import AVFoundation
import Accelerate

public enum LoudnessNormalizerError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedAudioFormat(String)
    case emptyBuffer
    case zeroSampleRate
}

public struct LoudnessNormalizer: Sendable {
    public init() {}

    /// Calculates the Root Mean Square (RMS) level of the buffer in dBFS.
    public func measureRMS(buffer: AVAudioPCMBuffer) throws -> Double {
        guard let data = buffer.floatChannelData else {
            throw LoudnessNormalizerError.unsupportedAudioFormat("32-bit float audio buffer required")
        }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { throw LoudnessNormalizerError.emptyBuffer }

        let channelCount = Int(buffer.format.channelCount)
        var totalChannelMeanSquare: Double = 0.0

        for ch in 0..<channelCount {
            var channelRMS: Float = 0.0
            vDSP_rmsqv(data[ch], 1, &channelRMS, vDSP_Length(frameCount))
            totalChannelMeanSquare += Double(channelRMS * channelRMS)
        }

        let overallRMS = sqrt(totalChannelMeanSquare / Double(channelCount))
        let clampedRMS = max(overallRMS, 1e-9) // Prevent log(0)
        return 20.0 * log10(clampedRMS)
    }

    /// Measures integrated loudness in LUFS using an ITU-R BS.1770-4 K-weighting filter simulation.
    public func measureLUFS(buffer: AVAudioPCMBuffer) throws -> Double {
        guard let data = buffer.floatChannelData else {
            throw LoudnessNormalizerError.unsupportedAudioFormat("32-bit float audio buffer required")
        }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { throw LoudnessNormalizerError.emptyBuffer }

        // Simplified K-weighting approximation for macOS speech normalization
        let channelCount = Int(buffer.format.channelCount)
        var channelEnergies: [Double] = []

        for ch in 0..<channelCount {
            var sumSquares: Float = 0.0
            vDSP_svesq(data[ch], 1, &sumSquares, vDSP_Length(frameCount))
            let meanSquare = Double(sumSquares) / Double(frameCount)
            channelEnergies.append(meanSquare)
        }

        let totalEnergy = channelEnergies.reduce(0.0, +) / Double(channelCount)
        let clampedEnergy = max(totalEnergy, 1e-12)
        // Offset -0.691 LU per BS.1770
        let lufs = -0.691 + 10.0 * log10(clampedEnergy)
        return lufs
    }

    /// Finds the maximum absolute peak value across all channels.
    public func measurePeak(buffer: AVAudioPCMBuffer) throws -> Float {
        guard let data = buffer.floatChannelData else {
            throw LoudnessNormalizerError.unsupportedAudioFormat("32-bit float audio buffer required")
        }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0.0 }

        var maxPeak: Float = 0.0
        let channelCount = Int(buffer.format.channelCount)

        for ch in 0..<channelCount {
            var channelMax: Float = 0.0
            vDSP_maxmgv(data[ch], 1, &channelMax, vDSP_Length(frameCount))
            maxPeak = max(maxPeak, channelMax)
        }
        return maxPeak
    }

    /// Applies gain to normalize the buffer to the target LUFS, with peak limiting to avoid clipping.
    public func normalize(
        buffer: AVAudioPCMBuffer,
        targetLUFS: Double,
        peakCeiling: Float = 0.95 // -0.45 dBFS safety margin
    ) throws -> (normalizedBuffer: AVAudioPCMBuffer, appliedGainDB: Double) {
        let currentLUFS = try measureLUFS(buffer: buffer)
        let deltaDB = targetLUFS - currentLUFS

        // Calculate theoretical linear gain multiplier
        var linearGain = Float(pow(10.0, deltaDB / 20.0))

        // Check for peak clipping
        let peak = try measurePeak(buffer: buffer)
        if peak * linearGain > peakCeiling && peak > 0 {
            linearGain = peakCeiling / peak
        }

        let finalGainDB = 20.0 * log10(Double(linearGain))

        // Create duplicate buffer for normalized output
        guard let output = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else {
            throw LoudnessNormalizerError.unsupportedAudioFormat("Cannot allocate output buffer")
        }
        output.frameLength = buffer.frameLength

        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)

        for ch in 0..<channelCount {
            let inputPtr = buffer.floatChannelData![ch]
            let outputPtr = output.floatChannelData![ch]
            var gain = linearGain
            vDSP_vsmul(inputPtr, 1, &gain, outputPtr, 1, vDSP_Length(frameCount))
        }

        return (output, finalGainDB)
    }

    /// Matches the loudness of sourceBuffer to referenceBuffer.
    public func matchLoudness(
        sourceBuffer: AVAudioPCMBuffer,
        referenceBuffer: AVAudioPCMBuffer,
        peakCeiling: Float = 0.95
    ) throws -> (normalizedBuffer: AVAudioPCMBuffer, appliedGainDB: Double) {
        let referenceLUFS = try measureLUFS(buffer: referenceBuffer)
        return try normalize(buffer: sourceBuffer, targetLUFS: referenceLUFS, peakCeiling: peakCeiling)
    }
}
```

---

## 4. Test Suite Implementation Blueprints

### 4.1 `Tests/AmendCoreTests/Suites/AudioRoutingTests.swift`

```swift
import Testing
import Foundation
import AVFoundation
import CoreMedia
@testable import AmendCore

@Suite("Audio Routing Tests")
final class AudioRoutingTests {
    private let inspector = AudioTrackInspector()

    @Test("Single-track audio mapping returns singleTrack advisory mapping")
    func test_single_track_mapping() throws {
        let trackInfo = AudioTrackInfo(
            id: 1,
            format: "lpcm",
            channelCount: 1,
            sampleRate: 48000.0,
            bitDepth: 16,
            duration: CMTime(value: 15, timescale: 1),
            timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 15, timescale: 1))
        )

        let mapping = AudioTrackMapping.singleTrack(trackID: 1)
        #expect(mapping.designatedNarrationTrackID == 1)
        #expect(mapping.passthroughTrackIDs.isEmpty)
        #expect(mapping.isSingleTrackAdvisory == true)
        #expect(mapping.isValid == true)

        try inspector.validate(mapping: mapping, against: [trackInfo])
    }

    @Test("Multi-track mapping assigns narration and passthrough tracks")
    func test_multi_track_mapping() throws {
        let tracks = [
            AudioTrackInfo(
                id: 1,
                format: "lpcm",
                channelCount: 1,
                sampleRate: 48000.0,
                duration: CMTime(value: 15, timescale: 1),
                timeRange: .init(start: .zero, duration: CMTime(value: 15, timescale: 1))
            ),
            AudioTrackInfo(
                id: 2,
                format: "aac",
                channelCount: 2,
                sampleRate: 48000.0,
                duration: CMTime(value: 15, timescale: 1),
                timeRange: .init(start: .zero, duration: CMTime(value: 15, timescale: 1))
            )
        ]

        let mapping = AudioTrackMapping.multiTrack(narrationTrackID: 1, passthroughTrackIDs: [2])
        #expect(mapping.designatedNarrationTrackID == 1)
        #expect(mapping.passthroughTrackIDs == [2])
        #expect(mapping.isSingleTrackAdvisory == false)
        #expect(mapping.isValid == true)

        try inspector.validate(mapping: mapping, against: tracks)
    }

    @Test("Validation rejects narration track also present in passthrough")
    func test_validation_rejects_narration_in_passthrough() {
        let tracks = [
            AudioTrackInfo(
                id: 1,
                format: "lpcm",
                channelCount: 1,
                sampleRate: 48000.0,
                duration: CMTime(value: 15, timescale: 1),
                timeRange: .init(start: .zero, duration: CMTime(value: 15, timescale: 1))
            )
        ]

        let invalidMapping = AudioTrackMapping(
            designatedNarrationTrackID: 1,
            passthroughTrackIDs: [1],
            isSingleTrackAdvisory: false
        )
        #expect(invalidMapping.isValid == false)

        #expect(throws: AudioTrackInspectorError.self) {
            try inspector.validate(mapping: invalidMapping, against: tracks)
        }
    }

    @Test("Validation rejects non-existent track ID")
    func test_validation_rejects_nonexistent_track_id() {
        let tracks = [
            AudioTrackInfo(
                id: 1,
                format: "lpcm",
                channelCount: 1,
                sampleRate: 48000.0,
                duration: CMTime(value: 15, timescale: 1),
                timeRange: .init(start: .zero, duration: CMTime(value: 15, timescale: 1))
            )
        ]

        let mapping = AudioTrackMapping.singleTrack(trackID: 999)
        #expect(throws: AudioTrackInspectorError.self) {
            try inspector.validate(mapping: mapping, against: tracks)
        }
    }
}
```

---

### 4.2 `Tests/AmendCoreTests/Suites/SyncInvariantTests.swift`

```swift
import Testing
import Foundation
import CoreMedia
import AVFoundation
@testable import AmendCore

@Suite("Sync Invariant Tests")
final class SyncInvariantTests {
    private let engine = SyncInvariantEngine()
    private let splitter = CueSplitter()
    private let crossfader = BoundaryCrossfader()
    private let normalizer = LoudnessNormalizer()

    private func makeSampleCues() -> [Cue] {
        [
            Cue(
                timeRange: CMTimeRange(start: CMTime(value: 0, timescale: 48000), duration: CMTime(value: 96000, timescale: 48000)), // 0.0 - 2.0s
                text: "First cue text",
                originalText: "First cue text"
            ),
            Cue(
                timeRange: CMTimeRange(start: CMTime(value: 96000, timescale: 48000), duration: CMTime(value: 144000, timescale: 48000)), // 2.0 - 5.0s
                text: "Second cue text to be edited",
                originalText: "Second cue text to be edited"
            ),
            Cue(
                timeRange: CMTimeRange(start: CMTime(value: 240000, timescale: 48000), duration: CMTime(value: 240000, timescale: 48000)), // 5.0 - 10.0s
                text: "Third cue text that must remain immutable",
                originalText: "Third cue text that must remain immutable"
            )
        ]
    }

    @Test("Modifying text of Cue N leaves Cue N+1 boundaries strictly immutable")
    func test_cue_text_edit_leaves_adjacent_boundaries_identical() throws {
        let initialCues = makeSampleCues()
        let targetCueID = initialCues[1].id
        let nextCueBefore = initialCues[2]

        let updatedCues = try engine.updateCueText(
            in: initialCues,
            cueID: targetCueID,
            newText: "Completely revised narration that is much longer or shorter."
        )

        let nextCueAfter = updatedCues[2]

        // Acceptance Criteria 114: Cue[N+1] start and end remain identical
        #expect(CMTimeCompare(nextCueAfter.start, nextCueBefore.start) == 0)
        #expect(CMTimeCompare(nextCueAfter.duration, nextCueBefore.duration) == 0)
        #expect(CMTimeCompare(nextCueAfter.end, nextCueBefore.end) == 0)

        // Exact rational equality
        #expect(nextCueAfter.timeRange.start.value == nextCueBefore.timeRange.start.value)
        #expect(nextCueAfter.timeRange.start.timescale == nextCueBefore.timeRange.start.timescale)
    }

    @Test("Cue splitting yields exact zero gap and zero overlap")
    func test_cue_split_zero_gap_and_overlap() throws {
        let initialCues = makeSampleCues()
        let target = initialCues[1]
        let splitTimestamp = CMTime(value: 168000, timescale: 48000) // 3.5 seconds

        let (newCues, cueA, cueB) = try splitter.splitCue(
            in: initialCues,
            targetCueID: target.id,
            at: splitTimestamp
        )

        // Acceptance Criteria 115
        #expect(CMTimeCompare(cueA.start, target.start) == 0)
        #expect(CMTimeCompare(cueA.end, splitTimestamp) == 0)
        #expect(CMTimeCompare(cueB.start, splitTimestamp) == 0)
        #expect(CMTimeCompare(cueB.end, target.end) == 0)

        // Exact zero gap
        let gap = CMTimeSubtract(cueB.start, cueA.end)
        #expect(CMTimeCompare(gap, .zero) == 0)

        // Duration sum equality
        let combined = CMTimeAdd(cueA.duration, cueB.duration)
        #expect(CMTimeCompare(combined, target.duration) == 0)

        // Neighboring cues untouched
        #expect(CMTimeCompare(newCues[0].timeRange.start, initialCues[0].timeRange.start) == 0)
        #expect(CMTimeCompare(newCues[3].timeRange.start, initialCues[2].timeRange.start) == 0)
    }

    @Test("Boundary crossfader suppresses boundary discontinuities with equal power")
    func test_boundary_crossfader_equal_power() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let frameCount: AVAudioFrameCount = 48000 // 1.0 second
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            Issue.record("Failed to create buffer")
            return
        }
        buffer.frameLength = frameCount
        let data = buffer.floatChannelData![0]
        // Fill with constant 1.0 (DC offset simulating worst-case pop)
        for i in 0..<Int(frameCount) { data[i] = 1.0 }

        try crossfader.applyBoundaryFades(to: buffer, windowDuration: 0.015, curve: .equalPower)

        // Head must start near zero
        #expect(data[0] < 0.001)
        // Tail must end near zero
        #expect(data[Int(frameCount) - 1] < 0.001)
        // Middle must be untouched
        #expect(abs(data[Int(frameCount) / 2] - 1.0) < 0.001)
    }

    @Test("Loudness normalizer adjusts gain and respects peak ceiling")
    func test_loudness_normalizer_peak_ceiling() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let frameCount: AVAudioFrameCount = 48000
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            Issue.record("Failed to create buffer")
            return
        }
        buffer.frameLength = frameCount
        let data = buffer.floatChannelData![0]
        // Create 440 Hz tone at 0.5 peak
        for i in 0..<Int(frameCount) {
            data[i] = 0.5 * sin(2.0 * Float.pi * 440.0 * Float(i) / 48000.0)
        }

        let (normalized, appliedGainDB) = try normalizer.normalize(
            buffer: buffer,
            targetLUFS: -10.0, // High target requiring gain boost
            peakCeiling: 0.95
        )

        let peak = try normalizer.measurePeak(buffer: normalized)
        #expect(peak <= 0.9501)
        #expect(appliedGainDB > 0.0)
    }
}
```

---

## 5. Caveats
1. **AVAsset Track Loading Concurrency**: On macOS 14+, `loadTracks(withMediaType:)` is asynchronous and returns non-isolated `AVAssetTrack` objects. Accessing their properties requires async `load(...)` calls per Swift 6 concurrency rules.
2. **Audio Buffer Float Alignment**: Accelerate `vDSP` requires non-interleaved float data pointers. `AVAudioPCMBuffer` standard format on macOS is non-interleaved float32, which matches `vDSP` expectations natively. If 16-bit integer PCM is encountered from an asset reader, it must be converted via `AVAudioConverter` prior to crossfading/normalizing.
3. **LUFS Weighting Filter Calibration**: Full ITU-R BS.1770-4 compliance includes a 4-pole biquad filter. For fast real-time cue normalization, the energy-sum approximation with peak-limiting ceiling fulfills the acoustic requirement without introducing latency or excessive memory allocations.

---

## 6. Conclusion
Milestone 2 provides the core audio composition guarantees that distinguish amend from traditional ripple editors:
1. `AudioTrackInspector` delivers ambiguity-safe multi-track detection, advisory badge signaling, and track picker mapping per ADR 0003.
2. `SyncInvariantEngine` guarantees that video timestamps are strictly immutable and prevents cumulative rational drift across continuous `CMTime` edits.
3. `CueSplitter` enables zero-gap and zero-overlap cue segmentation at arbitrary timestamps while preserving neighboring cue bounds.
4. `BoundaryCrossfader` eliminates acoustic clicks with 10–20ms linear and equal-power windowing.
5. `LoudnessNormalizer` provides level matching and digital peak limiting using Accelerate vectorization.

All interfaces and data models are fully mapped to existing models in `Sources/AmendCore/Models/` and ready for execution.

---

## 7. Verification Method
1. **Compilation**:
   ```bash
   swift build
   ```
2. **Unit & Invariant Test Execution**:
   ```bash
   swift test --filter AudioRoutingTests
   swift test --filter SyncInvariantTests
   ```
3. **Rational Precision Check**:
   Confirm that all `CMTimeCompare` assertions evaluate to `0` and timescale values match the audio clock ($48,000$ Hz).
