# Handoff Report: Core Foundation, Storage & Security Architecture (Milestone 1)

**Investigator**: `m1_explorer_2` (Domain Models & Storage Architecture Explorer)  
**Assigned Directory**: `/Users/fady/Dev/amend/.agents/m1_explorer_2`  
**Target Milestone**: Milestone 1 (Core Foundation, Storage & Security)  
**Date**: 2026-09-16  

---

## 1. Observation

Direct empirical observations gathered from code inspection, specification documents, and live macOS runtime evaluation:

### 1.1 `CMTime` and `CMTimeRange` Codable Conformance
- Direct compilation test in Swift 6.4 (`swift -e 'import Foundation; import CoreMedia; JSONEncoder().encode(CMTime())'`) failed with compiler errors:
  ```
  -e:11:28: error: instance method 'encode' requires that 'CMTime' conform to 'Encodable'
  Foundation.JSONEncoder.encode:2:11: note: where 'T' = 'CMTime'
  -e:14:37: error: instance method 'decode(_:from:)' requires that 'CMTime' conform to 'Decodable'
  Foundation.JSONDecoder.decode:2:11: note: where 'T' = 'CMTime'
  -e:22:33: error: instance method 'encode' requires that 'CMTimeRange' conform to 'Encodable'
  -e:25:42: error: instance method 'decode(_:from:)' requires that 'CMTimeRange' conform to 'Decodable'
  ```
- Conversely, checking standard protocol conformances showed that `CMTime` and `CMTimeRange` natively conform to `Sendable` and `Equatable` on macOS 14+ / Darwin 25.6:
  ```swift
  CMTime is Sendable, Equatable: true
  CMTimeRange is Sendable, Equatable: true
  ```
- Evaluated `@retroactive Codable` conformance for `CMTime` and `CMTimeRange` under Swift 6 with `-swift-version 5` and `-swift-version 6`:
  ```swift
  extension CMTime: @retroactive Codable { ... }
  extension CMTimeRange: @retroactive Codable { ... }
  ```
  The test succeeded with zero warnings and produced exact, deterministic round-trips preserving `value`, `timescale`, `flags`, and `epoch`.

### 1.2 APFS Volume Capabilities and Cloning Latency
- Queried local volume capabilities on `/Users/fady/Dev/amend` via `URLResourceValues`:
  ```swift
  volumeSupportsFileCloning: true
  volumeIdentifier: Optional(<67456400 00000000>)
  volumeUUIDString: Optional("D3618176-76AB-437C-A2DF-C4D0F3FA6A4E")
  volumeIsLocal: true
  volumeName: Optional("Macintosh HD")
  ```
- Executed `FileManager.default.copyItem` benchmark on a 10 MB payload on the APFS volume:
  - Duration: `0.000267042` seconds (~267 microseconds).
  - This confirms that `FileManager.default.copyItem(at:to:)` performs native APFS Copy-on-Write cloning (instant pointer duplicate without physical disk duplication) when invoked on the same APFS volume.
- Queried volume identifiers across paths (`/Users/fady/Dev/amend` vs `/tmp`):
  - Standardized paths via `resolvingSymlinksInPath()` confirmed both paths share the same `volumeIdentifier`.
  - APFS cloning cannot cross volume boundaries (e.g. from an external FAT32/exFAT drive or a separate APFS volume to the local container).

### 1.3 Security-Scoped Bookmark Creation, Resolution, and Stale Tracking
- Tested `URL.bookmarkData` with `options: .withSecurityScope`:
  - Output bookmark payload: 744 bytes.
  - Successfully resolved back to filesystem path via `URL(resolvingBookmarkData:options:relativeTo:bookmarkDataIsStale:)`.
  - `startAccessingSecurityScopedResource()` succeeded (`true`).
  - Tested moving/renaming the target file on disk:
    - Resolved bookmark path updated to the new path automatically.
    - `isStale` returned `true`, verifying that stale bookmarks can be detected and refreshed by the application.
  - In non-sandboxed command-line test runner environments where `.withSecurityScope` may throw, fallback to standard bookmark options `[]` succeeded (952 bytes).

### 1.4 Domain Model Specifications in Authoritative Sources
- `ORIGINAL_REQUEST.md:46-48`:
  - 1 audio track -> Narration with single-track advisory badge.
  - >1 audio tracks -> Track Picker modal designating Narration vs Passthrough tracks.
  - Destination `volumeSupportsFileCloning` checked: clones via `FileManager.copyItem`, falls back to security-scoped bookmarks without full copying.
  - Records in `project.json` whether source is `cloned` or `externalBookmark`.
- `PROJECT.md:196-232`:
  - `SourceStorageMode`: `.cloned(relativePath:)` vs `.externalBookmark(bookmarkData:, originalPath:)`.
  - `ProjectMetadata`: `id` (UUID), `name` (String), `sourceStorageMode`, `designatedNarrationTrackID`, `passthroughTrackIDs`, `totalDuration`, `roomToneRelativePath`, `createdAt`, `updatedAt`.
  - `Cue`: `id` (UUID), `timeRange` (CMTimeRange - immutable slot), `text` (String), `originalText` (String), `audioWAVRelativePath` (String?), `editState` (`CueEditState`), `overflowDelta` (CMTime?).
  - `CueEditState`: `original`, `edited`, `synthesized`, `overflowGated`, `forceFitted`.
- `spec_miner_fixtures_0/handoff.md:483`:
  - Notes test checking `sourceMode` property equals `"cloned"` or `"externalBookmark"`. Supporting dual property access (`sourceStorageMode` and `sourceMode`) prevents test breakage.

---

## 2. Logic Chain

1. **Premise**: `CMTime` and `CMTimeRange` are C-struct types from CoreMedia that do not conform to `Codable` in Foundation (Observation 1.1).
   - *Deduction*: Core domain models `Cue` and `ProjectMetadata` cannot be serialized to JSON via standard `JSONEncoder` unless explicit `Codable` conformances exist.
   - *Deduction*: Providing `@retroactive Codable` conformances in `AmendCore` (or dedicated extensions) that encode `value`, `timescale`, `flags`, and `epoch` guarantees lossless rational time serialization without floating-point precision loss.

2. **Premise**: `Cue.timeRange` is defined with `public let timeRange: CMTimeRange` (Observation 1.4).
   - *Deduction*: Immutability of the slot boundary is enforced by the Swift compiler. A cue's temporal window cannot be mutated in place; text edits or synthesized audio replacements preserve `Cue[N].timeRange` intrinsically.
   - *Deduction*: Cue splitting operations must return two new `Cue` instances whose start and end times sum to the parent cue's duration with zero gap and zero overlap.

3. **Premise**: APFS copy-on-write cloning via `FileManager.copyItem` executes in microseconds on the same APFS volume, but physical file copying across volumes takes seconds to minutes and wastes gigabytes (Observation 1.2, ADR 0004).
   - *Deduction*: `APFSCloner` must perform two checks prior to cloning:
     1. Destination volume reports `volumeSupportsFileCloning == true`.
     2. Source file and destination bundle share the exact same `volumeIdentifier`.
   - *Deduction*: If either condition fails, the cloner must abort the copy and invoke `BookmarkManager` to create a security-scoped bookmark.

4. **Premise**: Media imported from removable media or external volumes may be renamed or moved between user sessions (Observation 1.3, Edge Case 14).
   - *Deduction*: When resolving a bookmark from `project.json`, `BookmarkManager` must inspect `bookmarkDataIsStale`. If stale, `BookmarkManager` automatically re-generates and updates the bookmark data in `ProjectMetadata`.

5. **Premise**: `ProjectBundle` must be resilient to power loss or unexpected crashes during editing (Requirement R3, ADR 0004).
   - *Deduction*: `ProjectBundleSerializer` must write `project.json` using atomic disk writes (`Data.WritingOptions.atomic`), ensuring that a partially written file never corrupts project state.
   - *Deduction*: `project.json` must store `ProjectMetadata` with an embedded `cues: [Cue]` array defaulting to `[]`, allowing direct single-file deserialization of the entire project state while maintaining clear separation between project attributes and cue slices.

---

## 3. Caveats

1. **APFS Cloning Across Separate Containers**:
   Even if two APFS volumes exist on the same physical SSD, if they belong to different APFS container partitions, block-level cloning is not supported by the kernel and `FileManager.copyItem` will fall back to physical copying unless checked. Comparing `volumeIdentifier` prevents this edge case.
2. **Command-Line & Unit Test Sandbox Permissions**:
   When unit tests run under `swift test` in the terminal, the process is not sandboxed. Calling `URL.bookmarkData(options: .withSecurityScope)` in a non-sandboxed process can succeed or throw depending on macOS version and entitlements. `BookmarkManager` must fall back to standard bookmark options `[]` if `.withSecurityScope` fails during unit testing.
3. **Floating Point vs Rational CMTime**:
   `CMTime` values must always be serialized and deserialized using their integer `value` and `timescale` fields, never as `Double` seconds. Double precision accumulates rounding errors across repeated splits and edits.
4. **No Plaintext Secrets**:
   `ProjectMetadata` and `project.json` must strictly contain no API keys, bearer tokens, or user passwords. Cloud credentials must be handled exclusively by `KeychainVault` (Milestone 1, Explorer 3 focus).

---

## 4. Conclusion & Concrete Implementation Recommendations

The following exact designs and file structures are recommended for the Milestone 1 Worker:

### 4.1 Target File Layout in `Sources/AmendCore/`
```
Sources/AmendCore/
├── Models/
│   ├── CMTime+Codable.swift         # Lossless rational Codable extensions for CMTime & CMTimeRange
│   ├── CueEditState.swift           # Enum: original, edited, synthesized, overflowGated, forceFitted
│   ├── Cue.swift                    # Identifiable, Codable immutable slot model
│   ├── AudioTrackMapping.swift      # Multi-track routing & single-track advisory model
│   ├── SourceStorageMode.swift      # Cloned relative path vs security-scoped bookmark
│   ├── ProjectMetadata.swift        # Root project metadata model
│   └── ProjectBundle.swift          # Bundle directory structure and URL resolution
└── Storage/
    ├── APFSCloner.swift             # Volume capability checker and FileManager CoW cloner
    ├── BookmarkManager.swift        # Security-scoped bookmark creation, resolution, stale handling
    └── ProjectBundleSerializer.swift # Atomic project.json read/write and bundle initialization
```

---

### 4.2 Exact Code Specifications for Worker

#### 1. `Models/CMTime+Codable.swift`
```swift
import Foundation
import CoreMedia

extension CMTime: @retroactive Codable {
    enum CodingKeys: String, CodingKey {
        case value
        case timescale
        case flags
        case epoch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(Int64.self, forKey: .value)
        let timescale = try container.decode(Int32.self, forKey: .timescale)
        let flags = try container.decode(UInt32.self, forKey: .flags)
        let epoch = try container.decode(Int64.self, forKey: .epoch)
        self.init(value: value, timescale: timescale, flags: CMTimeFlags(rawValue: flags), epoch: epoch)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        try container.encode(timescale, forKey: .timescale)
        try container.encode(flags.rawValue, forKey: .flags)
        try container.encode(epoch, forKey: .epoch)
    }
}

extension CMTimeRange: @retroactive Codable {
    enum CodingKeys: String, CodingKey {
        case start
        case duration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let start = try container.decode(CMTime.self, forKey: .start)
        let duration = try container.decode(CMTime.self, forKey: .duration)
        self.init(start: start, duration: duration)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        try container.encode(duration, forKey: .duration)
    }
}
```

#### 2. `Models/CueEditState.swift` & `Models/Cue.swift`
```swift
import Foundation
import CoreMedia

public enum CueEditState: String, Codable, Equatable, Sendable, CaseIterable {
    case original
    case edited
    case synthesized
    case overflowGated
    case forceFitted
}

public struct Cue: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timeRange: CMTimeRange // Immutable slot boundaries
    public var text: String
    public var originalText: String
    public var audioWAVRelativePath: String?
    public var editState: CueEditState
    public var overflowDelta: CMTime? // Set when exceeding duration > 8%

    public init(
        id: UUID = UUID(),
        timeRange: CMTimeRange,
        text: String,
        originalText: String? = nil,
        audioWAVRelativePath: String? = nil,
        editState: CueEditState = .original,
        overflowDelta: CMTime? = nil
    ) {
        self.id = id
        self.timeRange = timeRange
        self.text = text
        self.originalText = originalText ?? text
        self.audioWAVRelativePath = audioWAVRelativePath
        self.editState = editState
        self.overflowDelta = overflowDelta
    }

    public var start: CMTime { timeRange.start }
    public var duration: CMTime { timeRange.duration }
    public var end: CMTime { timeRange.end }
}
```

#### 3. `Models/AudioTrackMapping.swift`
```swift
import Foundation

public struct AudioTrackMapping: Codable, Equatable, Sendable {
    public var designatedNarrationTrackID: Int
    public var passthroughTrackIDs: [Int]
    public var isSingleTrackAdvisory: Bool

    public init(
        designatedNarrationTrackID: Int,
        passthroughTrackIDs: [Int] = [],
        isSingleTrackAdvisory: Bool = false
    ) {
        self.designatedNarrationTrackID = designatedNarrationTrackID
        self.passthroughTrackIDs = passthroughTrackIDs
        self.isSingleTrackAdvisory = isSingleTrackAdvisory
    }

    public static func singleTrack(trackID: Int) -> AudioTrackMapping {
        AudioTrackMapping(
            designatedNarrationTrackID: trackID,
            passthroughTrackIDs: [],
            isSingleTrackAdvisory: true
        )
    }

    public static func multiTrack(narrationTrackID: Int, passthroughTrackIDs: [Int]) -> AudioTrackMapping {
        AudioTrackMapping(
            designatedNarrationTrackID: narrationTrackID,
            passthroughTrackIDs: passthroughTrackIDs,
            isSingleTrackAdvisory: false
        )
    }

    public var allTrackIDs: [Int] {
        [designatedNarrationTrackID] + passthroughTrackIDs
    }

    public var isValid: Bool {
        !passthroughTrackIDs.contains(designatedNarrationTrackID) &&
        (!isSingleTrackAdvisory || passthroughTrackIDs.isEmpty)
    }
}
```

#### 4. `Models/SourceStorageMode.swift` & `Models/ProjectMetadata.swift`
```swift
import Foundation
import CoreMedia

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
    public var isSingleTrackAdvisory: Bool
    public var totalDuration: CMTime
    public var roomToneRelativePath: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var cues: [Cue]

    // Compatibility accessor matching spec miner test criteria
    public var sourceMode: SourceStorageMode {
        get { sourceStorageMode }
        set { sourceStorageMode = newValue }
    }

    public var audioTrackMapping: AudioTrackMapping {
        get {
            AudioTrackMapping(
                designatedNarrationTrackID: designatedNarrationTrackID,
                passthroughTrackIDs: passthroughTrackIDs,
                isSingleTrackAdvisory: isSingleTrackAdvisory
            )
        }
        set {
            designatedNarrationTrackID = newValue.designatedNarrationTrackID
            passthroughTrackIDs = newValue.passthroughTrackIDs
            isSingleTrackAdvisory = newValue.isSingleTrackAdvisory
        }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        sourceStorageMode: SourceStorageMode,
        designatedNarrationTrackID: Int,
        passthroughTrackIDs: [Int] = [],
        isSingleTrackAdvisory: Bool = false,
        totalDuration: CMTime,
        roomToneRelativePath: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        cues: [Cue] = []
    ) {
        self.id = id
        self.name = name
        self.sourceStorageMode = sourceStorageMode
        self.designatedNarrationTrackID = designatedNarrationTrackID
        self.passthroughTrackIDs = passthroughTrackIDs
        self.isSingleTrackAdvisory = isSingleTrackAdvisory
        self.totalDuration = totalDuration
        self.roomToneRelativePath = roomToneRelativePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.cues = cues
    }

    enum CodingKeys: String, CodingKey {
        case id, name, sourceStorageMode, sourceMode
        case designatedNarrationTrackID, passthroughTrackIDs, isSingleTrackAdvisory
        case totalDuration, roomToneRelativePath, createdAt, updatedAt, cues
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        if let mode = try c.decodeIfPresent(SourceStorageMode.self, forKey: .sourceStorageMode) {
            sourceStorageMode = mode
        } else if let mode = try c.decodeIfPresent(SourceStorageMode.self, forKey: .sourceMode) {
            sourceStorageMode = mode
        } else {
            throw DecodingError.keyNotFound(CodingKeys.sourceStorageMode, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "No source storage mode found"))
        }
        designatedNarrationTrackID = try c.decode(Int.self, forKey: .designatedNarrationTrackID)
        passthroughTrackIDs = try c.decodeIfPresent([Int].self, forKey: .passthroughTrackIDs) ?? []
        isSingleTrackAdvisory = try c.decodeIfPresent(Bool.self, forKey: .isSingleTrackAdvisory) ?? false
        totalDuration = try c.decode(CMTime.self, forKey: .totalDuration)
        roomToneRelativePath = try c.decodeIfPresent(String.self, forKey: .roomToneRelativePath)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        cues = try c.decodeIfPresent([Cue].self, forKey: .cues) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(sourceStorageMode, forKey: .sourceStorageMode)
        try c.encode(designatedNarrationTrackID, forKey: .designatedNarrationTrackID)
        try c.encode(passthroughTrackIDs, forKey: .passthroughTrackIDs)
        try c.encode(isSingleTrackAdvisory, forKey: .isSingleTrackAdvisory)
        try c.encode(totalDuration, forKey: .totalDuration)
        try c.encodeIfPresent(roomToneRelativePath, forKey: .roomToneRelativePath)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(cues, forKey: .cues)
    }
}
```

#### 5. `Models/ProjectBundle.swift`
```swift
import Foundation

public struct ProjectBundle: Equatable, Sendable {
    public static let packageExtension = "amend"
    public static let projectFileName = "project.json"

    public let rootURL: URL
    public var metadata: ProjectMetadata

    public var cues: [Cue] {
        get { metadata.cues }
        set { metadata.cues = newValue }
    }

    public var projectJSONURL: URL {
        rootURL.appendingPathComponent(Self.projectFileName)
    }

    public var audioDirectoryURL: URL {
        rootURL.appendingPathComponent("audio")
    }

    public var cuesAudioDirectoryURL: URL {
        audioDirectoryURL.appendingPathComponent("cues")
    }

    public var waveformsDirectoryURL: URL {
        rootURL.appendingPathComponent("waveforms")
    }

    public var thumbnailsDirectoryURL: URL {
        rootURL.appendingPathComponent("thumbnails")
    }

    public init(rootURL: URL, metadata: ProjectMetadata) {
        self.rootURL = rootURL
        self.metadata = metadata
    }
}
```

#### 6. `Storage/APFSCloner.swift`
```swift
import Foundation

public enum APFSCloningError: Error, LocalizedError {
    case unsupportedVolume
    case crossVolumeCloningUnsupported
    case cloningFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVolume:
            return "The destination volume does not support APFS copy-on-write cloning."
        case .crossVolumeCloningUnsupported:
            return "Source and destination are on different filesystem volumes; cloning is impossible."
        case .cloningFailed(let err):
            return "APFS cloning failed: \(err.localizedDescription)"
        }
    }
}

public struct APFSCloner: Sendable {
    public static func volumeSupportsCloning(at url: URL) -> Bool {
        let stdURL = url.resolvingSymlinksInPath()
        guard let values = try? stdURL.resourceValues(forKeys: [.volumeSupportsFileCloningKey]),
              let supported = values.volumeSupportsFileCloning else {
            return false
        }
        return supported
    }

    public static func areOnSameVolume(_ url1: URL, _ url2: URL) -> Bool {
        let std1 = url1.resolvingSymlinksInPath()
        let std2 = url2.resolvingSymlinksInPath()
        guard let v1 = try? std1.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let v2 = try? std2.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else {
            return false
        }
        return (v1 as AnyObject).isEqual(v2)
    }

    public static func canClone(from source: URL, to destination: URL) -> Bool {
        volumeSupportsCloning(at: destination) && areOnSameVolume(source, destination)
    }

    public static func clone(from source: URL, to destination: URL) throws {
        guard volumeSupportsCloning(at: destination.deletingLastPathComponent()) else {
            throw APFSCloningError.unsupportedVolume
        }
        guard areOnSameVolume(source, destination.deletingLastPathComponent()) else {
            throw APFSCloningError.crossVolumeCloningUnsupported
        }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw APFSCloningError.cloningFailed(error)
        }
    }
}
```

#### 7. `Storage/BookmarkManager.swift`
```swift
import Foundation

public enum BookmarkError: Error, LocalizedError {
    case creationFailed(Error)
    case resolutionFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .creationFailed(let err):
            return "Failed to create security-scoped bookmark: \(err.localizedDescription)"
        case .resolutionFailed(let err):
            return "Failed to resolve security-scoped bookmark: \(err.localizedDescription)"
        }
    }
}

public struct BookmarkManager: Sendable {
    public static func createBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            // Fallback for non-sandboxed environments (e.g. CLI tools / unit tests)
            do {
                return try url.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } catch let fallbackErr {
                throw BookmarkError.creationFailed(fallbackErr)
            }
        }
    }

    public static func resolveBookmark(data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
        } catch {
            do {
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                return (url, isStale)
            } catch let fallbackErr {
                throw BookmarkError.resolutionFailed(fallbackErr)
            }
        }
    }

    public static func withSecurityScopedAccess<T>(to url: URL, block: (URL) throws -> T) throws -> T {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try block(url)
    }
}
```

#### 8. `Storage/ProjectBundleSerializer.swift`
```swift
import Foundation
import CoreMedia

public enum ProjectBundleSerializerError: Error, LocalizedError {
    case invalidBundleDirectory(URL)
    case missingProjectJSON(URL)
    case unresolvableMedia(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidBundleDirectory(let url):
            return "Path is not a valid project directory: \(url.path)"
        case .missingProjectJSON(let url):
            return "project.json not found in bundle: \(url.path)"
        case .unresolvableMedia(let err):
            return "Failed to resolve project source media: \(err.localizedDescription)"
        }
    }
}

public struct ProjectBundleSerializer: Sendable {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func createBundle(
        at destinationURL: URL,
        sourceMediaURL: URL,
        name: String,
        designatedNarrationTrackID: Int,
        passthroughTrackIDs: [Int] = [],
        isSingleTrackAdvisory: Bool = false,
        totalDuration: CMTime
    ) throws -> ProjectBundle {
        var bundleURL = destinationURL
        if bundleURL.pathExtension != ProjectBundle.packageExtension {
            bundleURL = bundleURL.appendingPathExtension(ProjectBundle.packageExtension)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: bundleURL.appendingPathComponent("audio/cues"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bundleURL.appendingPathComponent("waveforms"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bundleURL.appendingPathComponent("thumbnails"), withIntermediateDirectories: true)

        let sourceMode: SourceStorageMode
        if APFSCloner.canClone(from: sourceMediaURL, to: bundleURL) {
            let ext = sourceMediaURL.pathExtension.isEmpty ? "mp4" : sourceMediaURL.pathExtension
            let clonedRelative = "source.\(ext)"
            let targetClonedURL = bundleURL.appendingPathComponent(clonedRelative)
            do {
                try APFSCloner.clone(from: sourceMediaURL, to: targetClonedURL)
                sourceMode = .cloned(relativePath: clonedRelative)
            } catch {
                let bookmarkData = try BookmarkManager.createBookmark(for: sourceMediaURL)
                sourceMode = .externalBookmark(bookmarkData: bookmarkData, originalPath: sourceMediaURL.path)
            }
        } else {
            let bookmarkData = try BookmarkManager.createBookmark(for: sourceMediaURL)
            sourceMode = .externalBookmark(bookmarkData: bookmarkData, originalPath: sourceMediaURL.path)
        }

        let metadata = ProjectMetadata(
            name: name,
            sourceStorageMode: sourceMode,
            designatedNarrationTrackID: designatedNarrationTrackID,
            passthroughTrackIDs: passthroughTrackIDs,
            isSingleTrackAdvisory: isSingleTrackAdvisory,
            totalDuration: totalDuration,
            cues: []
        )

        let bundle = ProjectBundle(rootURL: bundleURL, metadata: metadata)
        try save(bundle: bundle)
        return bundle
    }

    public static func load(from bundleURL: URL) throws -> ProjectBundle {
        let projectJSON = bundleURL.appendingPathComponent(ProjectBundle.projectFileName)
        guard FileManager.default.fileExists(atPath: projectJSON.path) else {
            throw ProjectBundleSerializerError.missingProjectJSON(bundleURL)
        }

        let data = try Data(contentsOf: projectJSON)
        let metadata = try makeDecoder().decode(ProjectMetadata.self, from: data)

        // Ensure cache directories exist
        let fm = FileManager.default
        try? fm.createDirectory(at: bundleURL.appendingPathComponent("audio/cues"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: bundleURL.appendingPathComponent("waveforms"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: bundleURL.appendingPathComponent("thumbnails"), withIntermediateDirectories: true)

        return ProjectBundle(rootURL: bundleURL, metadata: metadata)
    }

    public static func save(bundle: ProjectBundle) throws {
        var updatedMetadata = bundle.metadata
        updatedMetadata.updatedAt = Date()

        let data = try makeEncoder().encode(updatedMetadata)
        try data.write(to: bundle.projectJSONURL, options: .atomic)
    }

    public static func resolveSourceMediaURL(for bundle: ProjectBundle) throws -> URL {
        switch bundle.metadata.sourceStorageMode {
        case .cloned(let relativePath):
            return bundle.rootURL.appendingPathComponent(relativePath)
        case .externalBookmark(let bookmarkData, _):
            let (resolvedURL, isStale) = try BookmarkManager.resolveBookmark(data: bookmarkData)
            if isStale {
                if let refreshed = try? BookmarkManager.createBookmark(for: resolvedURL) {
                    var mutableBundle = bundle
                    mutableBundle.metadata.sourceStorageMode = .externalBookmark(
                        bookmarkData: refreshed,
                        originalPath: resolvedURL.path
                    )
                    try? save(bundle: mutableBundle)
                }
            }
            return resolvedURL
        }
    }
}
```

---

## 5. Verification Method

To independently verify these designs and models without modifying repo files:

1. **Inline Swift Execution Test**:
   Execute the verification test suite in terminal:
   ```bash
   swift -swift-version 5 -e '
   import Foundation
   import CoreMedia
   // Run test script verifying Codable round-trip, APFS clone, BookmarkManager, and ProjectBundleSerializer
   '
   ```
   *Pass criteria*: All assertions evaluate to true, exit code is 0.

2. **Milestone 1 Worker Test Execution (`StorageAPFSTests`)**:
   Once the Worker places these files into `Sources/AmendCore/` and `Tests/AmendCoreTests/Suites/StorageAPFSTests.swift`:
   ```bash
   swift test --filter StorageAPFSTests
   ```
   *Assertions to check*:
   - `testAPFSCloneOnSupportedVolume`: Verifies `FileManager.copyItem` on local APFS clone creates `source.mp4` with instant latency.
   - `testBookmarkFallbackOnForeignVolume`: Mocks non-clonable condition or cross-volume path, verifying bookmark creation and zero copy.
   - `testProjectJSONRoundTrip`: Verifies `project.json` parses with ISO8601 dates, UUIDs, and rational `CMTime`.
   - `testSecretScanner`: Verifies that serialized `project.json` contains zero API keys or plaintext credentials.

3. **Invalidation Conditions**:
   - If macOS removes `@retroactive` support or changes `CMTime` layout (invalidated if CoreMedia introduces official Codable conformance in a newer SDK).
   - If Apple changes `FileManager.copyItem` semantics to deep copy on APFS (invalidated if clone test exceeds 5ms for 10MB).
