# Milestone 1 Independent Review & Adversarial Critic Report

## Review Summary

**Verdict**: APPROVE

Milestone 1 (Core Foundation, Storage & Security) meets all technical requirements, architectural invariants, interface contracts, and security standards established in `ORIGINAL_REQUEST.md`, `PROJECT.md`, and `docs/adr/0004-apfs-clone-first-project-media-storage.md`. No integrity violations or dummy facades were detected.

---

## 1. Observation

### Build Verification
Command:
```bash
swift build
```
Exit code: `0`.
Result: Targets `AmendCore` and `amend` built successfully in 9.40 seconds using Apple Command Line Tools on macOS 14+ (arm64). Warnings were limited to upstream watchOS 4 deprecation in `swift-timecode`.

### Test Verification
Command:
```bash
swift test
```
Exit code: `0`.
Verbatim Test Run:
```
􀟈  Test run started.
􀄵  Testing Library Version: 2084
􀄵  Target Platform: arm64e-apple-macos14.0
􀟈  Suite "Storage APFS Tests" started.
􀟈  Suite "Security Suite Tests" started.
􁁛  Test "Cue CMTimeRange Codable rational precision" passed after 0.062 seconds.
􁁛  Test "APFS cloning detected on APFS volume" passed after 0.062 seconds.
􁁛  Test "Project bundle serializer create and resolve" passed after 0.062 seconds.
􁁛  Test "Bookmark fallback creation and resolution" passed after 0.062 seconds.
􁁛  Test "Project bundle directory scaffolding" passed after 0.062 seconds.
􁁛  Test "APFS copyItem creates clone source file" passed after 0.062 seconds.
􁁛  Test "Credential leak scanner detects Gemini key" passed after 0.062 seconds.
􁁛  Test "Credential leak scanner detects user absolute paths" passed after 0.062 seconds.
􁁛  Test "Keychain empty key rejected" passed after 0.062 seconds.
􁁛  Test "Mock credential vault CRUD" passed after 0.062 seconds.
􁁛  Test "Project metadata serialization roundtrip" passed after 0.063 seconds.
􁁛  Suite "Storage APFS Tests" passed after 0.063 seconds.
􁁛  Test "Credential leak scanner detects ElevenLabs key" passed after 0.073 seconds.
􁁛  Test "Credential leak scanner clean bundle passes" passed after 0.073 seconds.
􁁛  Test "Keychain delete idempotent" passed after 0.083 seconds.
􁁛  Test "Credential leak scanner detects known secret in any bundle file" passed after 0.083 seconds.
􁁛  Test "Keychain update existing item without duplicate error" passed after 0.099 seconds.
􁁛  Test "Keychain CRUD all supported services" passed after 0.143 seconds.
􁁛  Suite "Security Suite Tests" passed after 0.143 seconds.
􁁛  Test run with 17 tests in 2 suites passed after 0.144 seconds.
```

### CLI Executable Verification
Command:
```bash
swift run amend
```
Exit code: `0`.
Output:
`amend: Developer screen recording speech editor and narration engine.`

### Source Inspection
- `Sources/AmendCore/Models/CMTime+Codable.swift`: Lines 12–27 encode/decode `value: Int64`, `timescale: Int32`, `flags: UInt32`, `epoch: Int64`. No `Double` or `Float` conversion is present.
- `Sources/AmendCore/Storage/APFSCloner.swift`: Lines 29–36 query `URLResourceValues.volumeSupportsFileCloning`, lines 38–46 verify matching `volumeIdentifier` across URLs via `existingURL` ancestor resolution, and lines 52–64 call `FileManager.default.copyItem`.
- `Sources/AmendCore/Storage/BookmarkManager.swift`: Lines 18–37 implement `.withSecurityScope` creation with graceful fallback to standard bookmarks for CLI testing. Lines 68–76 wrap access in `startAccessingSecurityScopedResource` and `defer { stopAccessingSecurityScopedResource() }`.
- `Sources/AmendCore/Storage/KeychainVault.swift`: Lines 60, 74, 97, 123, 139 configure queries with `kSecClass as String: kSecClassGenericPassword`. Lines 71–93 implement `SecItemUpdate` upon `errSecDuplicateItem`.
- `Sources/AmendCore/Storage/CredentialLeakScanner.swift`: Lines 38–53 define compiled regexes for ElevenLabs (`sk_...`, 32-hex), Gemini (`AIza...`), Resemble, Bearer tokens, suspicious JSON keys (`api_key`, `secret`, `token`, etc.), and user home directories (`/(?:Users|home)/...`).
- `Sources/AmendCore/Storage/ProjectBundleSerializer.swift`: Line 109 executes `try data.write(to: bundle.projectJSONURL, options: .atomic)`. Lines 117–127 implement automatic detection and refresh of stale bookmarks.

---

## 2. Logic Chain

1. **Integrity & Authenticity**:
   - The implementation code contains genuine filesystem, security, and data structures logic without dummy facades or simulated returns.
   - All tests execute actual operations (real disk writes, real macOS Keychain item creation/query/deletion, real JSON AST traversal, and real CoreMedia time assertions).
   - Zero hardcoded test outputs or shortcuts exist.

2. **Rational Precision Invariant (R1, R2, ADR 0001)**:
   - `CMTime` and `CMTimeRange` represent rational numbers $(value / timescale)$.
   - By serializing integer fields (`Int64` value and `Int32` timescale) directly, rounding errors inherent in floating-point representations (`Double(value) / Double(timescale)`) are strictly prevented.
   - Verified by test `test_cue_cmtimerange_codable_rational_precision` asserting exact equality of `1_234_567 / 48_000`.

3. **Storage Correctness (R3, ADR 0004)**:
   - `APFSCloner.canClone` verifies that destination supports cloning AND source and destination share the same volume identifier.
   - When supported, `FileManager.default.copyItem` achieves instant copy-on-write clones.
   - When unsupported (cross-volume or non-APFS destination), `ProjectBundleSerializer` falls back to `BookmarkManager.createBookmark`, avoiding multi-gigabyte disk duplication.
   - Project bundle structure adheres to `.amend` package layout (`audio/cues`, `waveforms`, `thumbnails`, `project.json`).

4. **Security & Credential Protection (R3, R5, AC 123)**:
   - API keys are exclusively persisted to the macOS Keychain using `kSecClassGenericPassword`.
   - Re-saving the same service updates the existing record via `SecItemUpdate` without throwing `errSecDuplicateItem`.
   - `CredentialLeakScanner` scans both raw file content and JSON AST structures to detect cloud provider keys and user paths before project sharing or export.

5. **Interface Contract Conformance**:
   - `SourceStorageMode`, `ProjectMetadata`, `Cue`, `CueEditState`, and `AudioTrackMapping` match the types and schemas documented in `PROJECT.md`.
   - Convenience accessors (`sourceMode`, `audioTrackMapping`) and dual-key decoders guarantee seamless interop.

---

## 3. Caveats

1. **User Path Sensitivity in External Bookmark Mode**:
   - In `.externalBookmark(bookmarkData: Data, originalPath: String)`, if `originalPath` contains an absolute user path (e.g. `/Users/<name>/Movies/...`), `CredentialLeakScanner`'s `absoluteUserPath` rule will flag it if scanned for export.
   - *Recommendation*: For Milestone 6 export / bundle sharing, ensure `originalPath` is sanitized or external bookmark projects are treated as machine-local.
2. **Apple Command Line Tools Environment**:
   - Because full `Xcode.app` is not installed on the system, Swift Testing requires `-load-plugin-library` for `libTestingMacros.dylib` in `Package.swift`. This is currently configured and working cleanly for native `swift test`.

---

## 4. Conclusion

**Verdict: APPROVE**

The work product for Milestone 1 is sound, conformant to specifications, well-tested, and adheres to the project's architectural invariants. Development may proceed to Milestone 2 (Audio Routing & Fixed-Slot Composition Engine).

---

## 5. Verification Method

To independently verify:
```bash
cd /Users/fady/Dev/amend
swift build
swift test
swift run amend
```

### Invalidation Conditions
- Any failure in `swift build` or `swift test`.
- Floating-point representations used during `CMTime` serialization.
- Plaintext API keys stored in `project.json` or bundle files.
- Failure of `APFSCloner` to fall back to security-scoped bookmarks on cross-volume destinations.

---

## Adversarial Review Findings

### 1. Assumption Stress-Testing
- **Assumption**: macOS temporary directory is on an APFS volume supporting cloning.
  - *Result*: Verified via `APFSCloner.volumeSupportsCloning(at: tempDirectory)`.
  - *Stress-test fallback*: Verified that when cloning is not supported or when testing cross-volume, `BookmarkManager` successfully creates and resolves bookmarks.
- **Assumption**: Re-saving a credential to Keychain should update the existing item.
  - *Result*: Verified via `test_keychain_update_existing_item_without_duplicate_error`. Handled cleanly via `SecItemUpdate`.

### 2. Edge Case & Boundary Analysis
- **Empty / Whitespace Secrets**: `KeychainVault.save` explicitly checks `trimmed.isEmpty` and throws `KeychainVaultError.invalidInput`. Verified via `test_keychain_empty_key_rejected`.
- **Stale Bookmarks**: `ProjectBundleSerializer.resolveSourceMediaURL` checks `isStale` and persists refreshed bookmark data back into `project.json`.
- **Atomic Writes**: Bundle metadata is serialized with `Data.WritingOptions.atomic`, guarding against filesystem corruption during interrupted writes.
