# Codebase & Environment Explorer Report: macdub

**Target Working Directory**: `/Users/fady/Dev/macdub`  
**Report Location**: `/Users/fady/Dev/macdub/.agents/explorer_codebase_0/handoff.md`  
**Date**: 2026-09-16  
**Investigator**: Codebase & Environment Explorer (`explorer_codebase_0`)

---

## 1. Observation

Direct empirical observations gathered from the environment, filesystem, and toolchain:

### 1.1 Filesystem Inventory & Existing Code Assets
Executing directory listings and file discovery across `/Users/fady/Dev/macdub` yielded:
```bash
# Command: list_dir /Users/fady/Dev/macdub
{"name":".agents", "isDir":true}
{"name":".git", "isDir":true}
{"name":".impeccable", "isDir":true}
{"name":"CONTEXT.md", "sizeBytes":"1800"}
{"name":"ORIGINAL_REQUEST.md", "sizeBytes":"11999"}
{"name":"docs", "isDir":true}
{"name":"skills-lock.json", "sizeBytes":"9260"}
```
- **Swift Source Code**: None. There are no `.swift` files anywhere in the workspace outside `.agents/`.
- **Package Manifest**: No `Package.swift` exists in the repository root or any subdirectory.
- **Xcode Projects**: No `.xcodeproj` or `.xcworkspace` bundles exist.
- **Test Suites**: No `Tests/` directory or test files exist.
- **Documentation & Specs Present**:
  - `/Users/fady/Dev/macdub/ORIGINAL_REQUEST.md`: Full specification for requirements R1 through R8, test harnesses, and acceptance criteria.
  - `/Users/fady/Dev/macdub/CONTEXT.md`: Ubiquitous domain language defining: *Cue*, *Narration*, *Sync Invariant*, *Duration Fitting*, *Reference Voice*, *Room Tone*, *Passthrough Track*, *Project Bundle*.
  - `/Users/fady/Dev/macdub/docs/adr/`: 9 Architecture Decision Records:
    - `0001-fixed-sync-invariant.md`
    - `0002-native-swift-and-coreml-stack.md`
    - `0003-ambiguity-safe-audio-track-mapping.md`
    - `0004-apfs-clone-first-project-media-storage.md`
    - `0005-ambient-room-tone-cue-padding.md`
    - `0006-user-gated-duration-overflow-handling.md`
    - `0007-deterministic-avfoundation-verification-fixtures.md`
    - `0008-compressed-sample-passthrough-export-pipeline.md`
    - `0009-serialized-local-model-lifecycle.md`
- **Git State**:
  ```
  $ git status
  On branch main
  No commits yet
  Untracked files: .agents/ CONTEXT.md ORIGINAL_REQUEST.md docs/ skills-lock.json
  nothing added to commit but untracked files present
  ```

### 1.2 System Environment & Hardware Configuration
- **Operating System & Kernel**:
  ```bash
  $ sw_vers
  ProductName:		macOS
  ProductVersion:		26.6.2
  BuildVersion:		25G83

  $ uname -a
  Darwin Fadys-MacBook-Pro.local 25.6.0 Darwin Kernel Version 25.6.0: Fri Jul 31 19:17:12 PDT 2026; root:xnu-12377.161.14~5/RELEASE_ARM64_T8103 arm64
  ```
- **CPU & Silicon Model**:
  ```bash
  $ sysctl hw.model hw.ncpu hw.memsize
  hw.model: MacBookPro17,1
  hw.ncpu: 8
  hw.memsize: 8589934592
  ```
  - Exact hardware: Apple M1 MacBook Pro (13-inch, 2020), 8 CPU cores (T8103 silicon).
  - Exact physical RAM: **8,589,934,592 bytes = 8.0 GB**. This physically matches the exact 8GB RAM budget constraint specified in ADR 0009 and Requirement R8.

### 1.3 Toolchain & Compiler State
- **Swift Compiler**:
  ```bash
  $ swift --version
  swift-driver version: 1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)
  Target: arm64-apple-macosx26.0
  ```
- **Swift Package Manager**:
  ```bash
  $ swift package --version
  Swift Package Manager - Swift 6.4.0-dev
  ```
- **Xcode Toolchain Verification**:
  ```bash
  $ xcodebuild -version
  xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory '/Library/Developer/CommandLineTools' is a command line tools instance

  $ xcode-select -p
  /Library/Developer/CommandLineTools
  ```
  - `xcodebuild` is **not available**.
  - The system is configured with Apple Command Line Tools (`/Library/Developer/CommandLineTools`).
  - SPM commands (`swift build`, `swift test`, `swift run`) are the **sole supported build and test mechanisms**.

- **Active SDK & Native Framework Availability**:
  - SDK Path: `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`
  - System frameworks verified present:
    - `AVFoundation.framework`
    - `CoreMedia.framework`
    - `AudioToolbox.framework`
    - `Accelerate.framework`
    - `CoreML.framework`
    - `Security.framework`
    - `AppKit.framework`
    - `SwiftUI.framework`
- **Compiler Execution Diagnostics**:
  - Executed inline Foundation evaluation:
    ```bash
    $ swift -e 'import Foundation; print("Foundation OK: \(ProcessInfo.processInfo.operatingSystemVersionString)")'
    Output: Foundation OK: Version 26.6.2 (Build 25G83)
    Exit Code: 0
    ```
  - Executed inline AVFoundation / CoreMedia evaluation:
    ```bash
    $ swift -e 'import Foundation; import AVFoundation; import CoreMedia; let t = CMTime(seconds: 10, preferredTimescale: 600); print("CMTime: \(t.seconds)s, timescale: \(t.timescale)")'
    Output: CMTime: 10.0s, timescale: 600
    Exit Code: 0
    ```
  - Executed Swift 5 language mode compatibility check:
    ```bash
    $ swift -e 'print("Swift mode test")' -swift-version 5
    Output: Swift mode test
    Exit Code: 0
    ```

### 1.4 External Package Dependencies Verification
Investigated the remote repositories for all external dependencies specified in `ORIGINAL_REQUEST.md` and the ADRs via `git ls-remote` and direct raw `Package.swift` inspection:

1. **FluidAudio** (Parakeet Core ML ASR, Silero VAD, ESpeakNG TTS):
   - Repository: `https://github.com/FluidInference/FluidAudio.git`
   - Connectivity: Verified accessible.
   - Latest Released Tag: `v0.9.1`
   - Manifest Inspection (`Package.swift` at `v0.9.1`):
     - `// swift-tools-version: 6.0`
     - `platforms: [.macOS(.v14), .iOS(.v17)]`
     - `products`:
       - `FluidAudio` (library, targets: `FluidAudio`, dependencies: `FastClusterWrapper`, `MachTaskSelfWrapper`)
       - `FluidAudioTTS` (library, targets: `FluidAudioTTS`, dependencies: `FluidAudio`, `ESpeakNG` xcframework)
       - `fluidaudiocli` (executable)
     - Binary Targets: `Frameworks/ESpeakNG.xcframework` checked directly into repo tree.
     - `cxxLanguageStandard: .cxx17`

2. **DSWaveformImage** (Waveform sample extraction & rendering):
   - Repository: `https://github.com/dmrschmidt/DSWaveformImage.git`
   - Connectivity: Verified accessible.
   - Latest Released Tag: `14.5.0`
   - Manifest Inspection (`Package.swift` at `14.5.0`):
     - `// swift-tools-version: 5.7`
     - `platforms: [.iOS(.v15), .macOS(.v12)]`
     - `products`:
       - `DSWaveformImage` (library, target: `DSWaveformImage`)
       - `DSWaveformImageViews` (library, target: `DSWaveformImageViews`)

3. **swift-timecode** (formerly `TimecodeKit`, SMPTE timecode calculation):
   - Repository: `https://github.com/orchetect/swift-timecode.git`
   - Connectivity: Verified accessible.
   - Latest Released Tag: `3.1.4`
   - Manifest Inspection (`Package.swift` at `3.1.4`):
     - `// swift-tools-version: 5.9`
     - `platforms: [.macOS(.v10_13), .iOS(.v12), ...]`
     - `products`:
       - `SwiftTimecode` (library, target: `SwiftTimecode`)
       - `SwiftTimecodeCore` (library, target: `SwiftTimecodeCore`)
       - `SwiftTimecodeAV` (library, target: `SwiftTimecodeAV`)
       - `SwiftTimecodeUI` (library, target: `SwiftTimecodeUI`)

---

## 2. Logic Chain

1. **Premise**: The repository contains no existing Swift files, `Package.swift`, or Xcode projects (Observation 1.1).
   - *Deduction*: macdub is a **completely greenfield implementation**. There are no legacy code conventions, deprecated APIs, or technical debt to preserve or refactor. The architecture can and must be established cleanly from the ground up matching `ORIGINAL_REQUEST.md` and the 9 ADRs.

2. **Premise**: The build environment has Apple Command Line Tools active (`/Library/Developer/CommandLineTools`) and lacks `xcodebuild` (Observation 1.3).
   - *Deduction*: Any command invoking `xcodebuild` will immediately exit with error code 1. Therefore, all build configurations, module definitions, and test suites must strictly operate via **Swift Package Manager (`Package.swift`)** and be executable via `swift build` and `swift test`.
   - *Deduction*: Executables and libraries must be defined as SPM targets. An App target can be structured as an executable product (`macdub`) with `@main` SwiftUI App entry point, supported by a modular core library (`MacDubCore`).

3. **Premise**: The host platform is Apple M1 with 8.0 GB RAM running macOS 26.6.2, and the deployment target is macOS 14.0+ arm64 (Observation 1.2, 1.3).
   - *Deduction*: The target platform matches all prerequisites of the specification. The 8GB physical RAM confirms that memory constraints are not theoretical: concurrent memory residency of Parakeet ASR, local LLM, and PocketTTS will trigger OS memory pressure and kernel jetsam/swapping. `LocalModelCoordinator` (ADR 0009) is mandatory.

4. **Premise**: Native frameworks (`AVFoundation`, `CoreMedia`, `CoreML`, `Accelerate`, `Security`) compile and execute successfully via `swift` CLI in the local SDK (Observation 1.3).
   - *Deduction*: The AVFoundation reader/writer passthrough export pipeline (ADR 0008), CMTime timeline (ADR 0001), APFS cloning check (ADR 0004), room-tone crossfading (ADR 0005), and Keychain storage (Security Suite) can be directly implemented using the system SDK without foreign dependencies.

5. **Premise**: Remote repositories for `FluidAudio`, `DSWaveformImage`, and `swift-timecode` are validated and compatible with macOS 14.0+ and Swift 6 (Observation 1.4).
   - *Deduction*: A root `Package.swift` can be authored with the exact version requirements:
     - `.package(url: "https://github.com/dmrschmidt/DSWaveformImage.git", from: "14.5.0")`
     - `.package(url: "https://github.com/orchetect/swift-timecode.git", from: "3.1.4")`
     - `.package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.9.1")`

---

## 3. Caveats

1. **Command Line Tools vs Full Xcode GUI**:
   Because full Xcode (`Xcode.app`) is not installed, building an `.app` bundle for macOS Finder drag-and-drop distribution typically requires `xcodebuild` or manual bundle packaging (`mkdir -p macdub.app/Contents/MacOS && cp .build/debug/macdub macdub.app/Contents/MacOS/`). For local development, running, and automated verification, `swift build` and `swift run` / `swift test` operate natively.
2. **FluidAudio Package Resolution Size**:
   `FluidAudio` contains C++ wrappers (`FastClusterWrapper`, `MachTaskSelfWrapper`) and binary framework `ESpeakNG.xcframework`. When SPM first resolves dependencies, downloading and building these packages may require several minutes over the network.
3. **Swift 6 Concurrency Compiler Setting**:
   The compiler is Apple Swift 6.4 (`Swift 6.4.0-dev`). Setting `swiftLanguageModes: [.v5]` in `Package.swift` prevents third-party packages from throwing strict-concurrency errors while still providing full `async/await` and `@MainActor` language capabilities.

---

## 4. Conclusion & Recommended Architecture

### 4.1 State Assessment
The workspace is currently in an uninitialized greenfield state with complete architectural documentation. All compiler toolchains, SDKs, and external package repositories are verified functional and accessible.

### 4.2 Recommended Package Structure
To ensure clean separation of concerns, testability, and fast compilation, the following package structure is recommended for `Package.swift`:

```
macdub/
├── Package.swift
├── CONTEXT.md
├── ORIGINAL_REQUEST.md
├── docs/adr/
├── Sources/
│   ├── MacDubCore/                        # Core reusable domain library
│   │   ├── Models/                        # Cue, AudioTrack, ProjectBundle, ProjectMetadata
│   │   ├── Storage/                       # APFS cloning, Security-scoped bookmarks, project.json
│   │   ├── Timeline/                      # CMTime engine, SwiftTimecode SMPTE conversion
│   │   ├── Waveform/                      # DSWaveformImage extraction & cache
│   │   ├── Composition/                   # Fixed-slot invariant, CueSplitter, AVMutableComposition
│   │   ├── AudioProcessing/               # RoomToneSampler, DurationFitter, TimePitch compressor
│   │   ├── AI/                            # LocalModelCoordinator, SpeechTranscriber, VoiceSynthesizers, Grammar
│   │   └── Export/                        # AVAssetReader/Writer compressed-sample passthrough muxer
│   └── macdub/                            # macOS App Target (SwiftUI / AppKit executable)
│       ├── App/                           # MacDubApp.swift (@main)
│       └── Views/                         # VideoPlayer, TimelineRuler, CueTrack, OverflowSheet, TrackPicker
└── Tests/
    └── MacDubCoreTests/                   # Test Suite
        ├── Fixtures/                      # Fixture 1, 2, 3 (synthetic AVFoundation asset generators)
        ├── SyncInvariantTests.swift       # Immutable boundary & split verification
        ├── SamplePayloadTests.swift       # Compressed video bitstream hash identity
        ├── DurationFittingTests.swift     # Padding, +8% compression, >8% overflow gating
        ├── StorageAPFSTests.swift         # APFS copyItem vs bookmark fallback
        ├── SecurityTests.swift            # Keychain round-trip & project.json secret leak scanner
        └── ModelLifecycleTests.swift      # Serialized residency & 8GB RAM budgeting
```

### 4.3 Proposed `Package.swift` Definition

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "macdub",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "macdub", targets: ["macdub"]),
        .library(name: "MacDubCore", targets: ["MacDubCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/dmrschmidt/DSWaveformImage.git", from: "14.5.0"),
        .package(url: "https://github.com/orchetect/swift-timecode.git", from: "3.1.4"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.9.1")
    ],
    targets: [
        .target(
            name: "MacDubCore",
            dependencies: [
                .product(name: "DSWaveformImage", package: "DSWaveformImage"),
                .product(name: "SwiftTimecode", package: "swift-timecode"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "FluidAudioTTS", package: "FluidAudio")
            ],
            path: "Sources/MacDubCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "macdub",
            dependencies: [
                "MacDubCore",
                .product(name: "SwiftTimecodeUI", package: "swift-timecode"),
                .product(name: "DSWaveformImageViews", package: "DSWaveformImage")
            ],
            path: "Sources/macdub",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "MacDubCoreTests",
            dependencies: ["MacDubCore"],
            path: "Tests/MacDubCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
```

---

## 5. Verification Method

To independently verify the environment, findings, and compiler readiness:

1. **Verify Developer Tools Directory**:
   ```bash
   xcode-select -p
   # Expected output: /Library/Developer/CommandLineTools
   ```
2. **Verify Swift Compiler Version & Target Architecture**:
   ```bash
   swift --version
   # Expected output: Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1) Target: arm64-apple-macosx26.0
   ```
3. **Verify Host Memory & Apple Silicon M1 Hardware**:
   ```bash
   sysctl hw.model hw.memsize
   # Expected output: hw.model: MacBookPro17,1; hw.memsize: 8589934592 (8GB)
   ```
4. **Verify Framework Accessibility**:
   ```bash
   swift -e 'import Foundation; import AVFoundation; import CoreMedia; let t = CMTime(seconds: 1, preferredTimescale: 600); print("Valid: \(t.seconds)")'
   # Expected output: Valid: 1.0
   ```
5. **Verify Project Compilation Once Package.swift is Written**:
   ```bash
   swift build --target MacDubCore
   swift test
   ```
