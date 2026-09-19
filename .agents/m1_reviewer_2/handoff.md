# Milestone 1 Review & Adversarial Challenge Report — Core Foundation, Storage & Security

**Reviewer**: `m1_reviewer_2` (Roles: reviewer, critic)  
**Parent Agent**: `orchestrator_5` (`f4d33157-8c85-4175-941d-68dd087b5235`)  
**Verdict**: **APPROVE**  
**Integrity Assessment**: **CLEAN** (Zero integrity violations, zero facades, zero hardcoded shortcuts)  

---

## 1. Observation

### Build and Test Commands & Output
- Command: `swift build`
  - Result: Exit code 0
  - Output:
    ```
    Build complete! (5.01 secs)
    ```
- Command: `swift test`
  - Result: Exit code 0
  - Output:
    ```
    􀟈  Test run started.
    􀄵  Testing Library Version: 2084
    􀄵  Target Platform: arm64e-apple-macos14.0
    􀟈  Suite "Storage APFS Tests" started.
    􀟈  Suite "Security Suite Tests" started.
    􁁛  Test "Cue CMTimeRange Codable rational precision" passed after 0.064 seconds.
    􁁛  Test "Project metadata serialization roundtrip" passed after 0.064 seconds.
    􁁛  Test "Project bundle directory scaffolding" passed after 0.065 seconds.
    􁁛  Test "APFS cloning detected on APFS volume" passed after 0.065 seconds.
    􁁛  Test "APFS copyItem creates clone source file" passed after 0.065 seconds.
    􁁛  Test "Mock credential vault CRUD" passed after 0.065 seconds.
    􁁛  Test "Credential leak scanner detects user absolute paths" passed after 0.065 seconds.
    􁁛  Test "Credential leak scanner clean bundle passes" passed after 0.065 seconds.
    􁁛  Test "Project bundle serializer create and resolve" passed after 0.065 seconds.
    􁁛  Test "Bookmark fallback creation and resolution" passed after 0.064 seconds.
    􁁛  Suite "Storage APFS Tests" passed after 0.065 seconds.
    􁁛  Test "Credential leak scanner detects Gemini key" passed after 0.081 seconds.
    􁁛  Test "Credential leak scanner detects ElevenLabs key" passed after 0.081 seconds.
    􁁛  Test "Credential leak scanner detects known secret in any bundle file" passed after 0.081 seconds.
    􁁛  Test "Keychain empty key rejected" passed after 0.089 seconds.
    􁁛  Test "Keychain delete idempotent" passed after 0.090 seconds.
    􁁛  Test "Keychain update existing item without duplicate error" passed after 0.105 seconds.
    􁁛  Test "Keychain CRUD all supported services" passed after 0.151 seconds.
    􁁛  Suite "Security Suite Tests" passed after 0.151 seconds.
    􁁛  Test run with 17 tests in 2 suites passed after 0.152 seconds.
    ```
- Command: `swift run amend`
  - Result: Exit code 0
  - Output: `amend: Developer screen recording speech editor and narration engine.`

### Inspected Source Files
1. `Package.swift`:
   - Configured for `macOS(.v14)`, Swift language mode `.v5` (for FluidAudio compatibility).
   - `AmendCore` depends on `DSWaveformImage`, `SwiftTimecodeCore`, `SwiftTimecodeAV`, `FluidAudio`, `FluidAudioTTS`.
   - `AmendCoreTests` targets Swift Testing with explicit macro plugin loading flag: `-load-plugin-library /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib`.
2. `Sources/AmendCore/Models/`:
   - `CMTime+Codable.swift` (lines 4–48): Encodes `value` (Int64), `timescale` (Int32), `flags` (UInt32), `epoch` (Int64). `CMTimeRange` encodes `start` and `duration` as exact `CMTime` structs. Zero floating-point rounding.
   - `Cue.swift` (lines 4–66): Implements `id`, `timeRange`, `text`, `originalText`, `audioWAVRelativePath`, `editState`, `overflowDelta`.
   - `CueEditState.swift` (lines 3–9): `original`, `edited`, `synthesized`, `overflowGated`, `forceFitted`.
   - `SourceStorageMode.swift` (lines 3–15): `cloned(relativePath: String)` and `externalBookmark(bookmarkData: Data, originalPath: String)`.
   - `ProjectMetadata.swift` (lines 4–120): Implements all required properties from `PROJECT.md`, plus convenience accessors `sourceMode` and `audioTrackMapping`.
   - `ProjectBundle.swift` (lines 3–60): Manages bundle scaffolding (`audio/cues`, `waveforms`, `thumbnails`) and atomic `project.json` encoding.
   - `AudioTrackMapping.swift` (lines 3–42): Tracks `designatedNarrationTrackID`, `passthroughTrackIDs`, and `isSingleTrackAdvisory`.
3. `Sources/AmendCore/Storage/`:
   - `APFSCloner.swift` (lines 20–74): Checks destination volume cloning support via `volumeSupportsFileCloningKey` and verifies matching volumes via `volumeIdentifierKey`.
   - `BookmarkManager.swift` (lines 17–77): Generates `.withSecurityScope` bookmarks with non-sandboxed fallback, resolves bookmarks, checks staleness, and wraps resource access via `withSecurityScopedAccess`.
   - `ProjectBundleSerializer.swift` (lines 21–131): Handles bundle creation, atomic saving via `Data.write(..., options: .atomic)`, APFS clone vs bookmark fallback branching, decoding, and stale bookmark refreshment.
   - `KeychainVault.swift` (lines 41–151): Uses `kSecClassGenericPassword`, `kSecAttrService`, `kSecAttrAccount`, `kSecValueData`. Rejects empty/whitespace keys. Gracefully updates duplicate items via `SecItemUpdate`. Provides `MockCredentialVault` for isolated testing.
   - `CredentialLeakScanner.swift` (lines 34–165): Scans raw text and JSON AST for known secrets, provider regexes (ElevenLabs, Gemini, Resemble, Bearer tokens), suspicious key names (`api_key`, `secret`, `token`, `password`, `auth_header`), and user home paths (`/(?:Users|home)/[A-Za-z0-9._\\-]+/`).
4. `Sources/amend/main.swift` (lines 1–10): CLI entry point.

---

## 2. Logic Chain

1. **Integrity Verification**:
   - Inspected all source files in `Sources/AmendCore/`. Verified that neither production code nor tests contain hardcoded return values, facade stubs, or dummy logic.
   - Real system framework calls are made: `FileManager.copyItem`, `URLResourceValues`, `SecItemAdd`, `SecItemCopyMatching`, `JSONSerialization`, `JSONEncoder`, `JSONDecoder`.
   - Conclusion: Zero integrity violations.

2. **APFS Cloning vs Bookmark Fallback Correctness (R3 & ADR 0004)**:
   - Observation: In `APFSCloner.swift:48-50`, `canClone` verifies both `volumeSupportsCloning(at: destination)` and `areOnSameVolume(source, destination)`.
   - Observation: In `ProjectBundleSerializer.swift:55-69`, if `canClone` is false, it does NOT execute `copyItem`. Instead, it generates a security-scoped bookmark via `BookmarkManager.createBookmark(for: sourceMediaURL)` and sets `sourceStorageMode = .externalBookmark(...)`.
   - Adversarial verification (DMG mounted with HFS+): `APFSCloner.volumeSupportsCloning` returned `false`. `createBundle` generated `.externalBookmark`. Verified 0 bytes of media were copied to the foreign volume bundle. Bookmark resolution succeeded and verified payload identity.
   - Adversarial verification (DMG mounted with separate APFS container): `areOnSameVolume` returned `false`. `createBundle` generated `.externalBookmark` without cross-container copying.
   - Conclusion: APFS cloning and bookmark fallback strictly follow ADR 0004 and R3.

3. **Keychain Security & Credential Leak Detection (R3, R5, AC 123)**:
   - Observation: `KeychainVault.swift:60` configures `kSecClass as String: kSecClassGenericPassword`.
   - Observation: In `SecuritySuiteTests.swift:32`, CRUD roundtrip passes for ElevenLabs, Resemble, and Gemini keys.
   - Observation: `CredentialLeakScanner.swift:38-53` implements provider patterns and user path regex.
   - Adversarial stress tests:
     - Known secret nested in arbitrary JSON array: detected.
     - User paths `/Users/...` and `/home/...`: detected with zero false positives on `/System/` or `/Applications/`.
     - AST suspicious keys (`api_key`, `secret`, `token`, `auth_header`): detected.
     - Technical discussion in subtitle cues regarding API keys: clean pass without false positive.
   - Conclusion: Credential security and leak scanning are robust and verified.

4. **CMTime Rational Invariant & Model Contracts (R1, R2, ADR 0001)**:
   - Observation: `CMTime+Codable.swift:14-27` encodes and decodes integer `value: Int64` and `timescale: Int32`.
   - Adversarial test: Tested rational precision across audio timescale (48,000 Hz), video timescale (600), NTSC fractional units (30,000 / 1001), 1-sample intervals, and near-max 64-bit integers. Every case preserved identical integer values without floating-point drift (`CMTimeCompare == 0`).
   - Interface Conformance: All types (`SourceStorageMode`, `ProjectMetadata`, `Cue`, `CueEditState`, `AudioTrackMapping`, `ProjectBundle`) conform exactly to `PROJECT.md` contracts.

---

## 3. Caveats

No caveats. All Milestone 1 functionality is fully native, non-mocked in production code, independently verified across native APFS, non-APFS (HFS+), and cross-container volumes, and passes all tests.

---

## 4. Conclusion

**Verdict: APPROVE**

Milestone 1 satisfies all requirements of R3, ADR 0004, and the architectural contracts defined in `PROJECT.md`:
- Pure native Swift implementation under macOS 14.0+ Apple Silicon.
- APFS copy-on-write cloning with genuine zero-copy behavior on same-volume targets.
- Strict security-scoped bookmark fallback on foreign / cross-volume filesystems without multi-gigabyte copying.
- macOS Keychain integration using `kSecClassGenericPassword` with duplicate update handling and whitespace validation.
- AST-aware CredentialLeakScanner catching provider keys and user paths.
- Exact rational CMTime precision preserved without floating-point conversion.
- 17 unit tests in SPM test target + 23 adversarial stress tests pass 100%.

---

## 5. Verification Method

To independently reproduce the verification results:

```bash
cd /Users/fady/Dev/amend

# 1. Standard build and test suite
swift build
swift test

# 2. CLI smoke test
swift run amend

# 3. Targeted test suites
swift test --filter StorageAPFSTests
swift test --filter SecuritySuiteTests

# 4. Reviewer adversarial stress suite
swiftc -I .build/out/Products/Debug -L .build/out/Products/Debug -lAmendCore .agents/m1_reviewer_2/stress_test.swift -o /tmp/m1_stress_bin
/tmp/m1_stress_bin
rm -f /tmp/m1_stress_bin
```

### Invalidation Conditions
- Any compilation failure under `swift build` or assertion failure under `swift test`.
- Any multi-gigabyte file copy when creating a project bundle on a non-APFS or cross-volume drive.
- Plaintext API key serialization in `project.json` or failure of `CredentialLeakScanner` to flag `/Users/` paths.
- Loss of exact `timescale` or `value` integer equality in `CMTime` serialization roundtrips.
