# Handoff Report: Security Credential Vault & Milestone 1 Unit Test Suite

- **Explorer**: `m1_explorer_3`
- **Milestone**: Milestone 1 (Core Foundation, Storage & Security)
- **Target**: Native macOS 14.0+, Swift 6.0, Apple Silicon (arm64)
- **Status**: Complete Investigation & Technical Design

---

## 1. Observation

### 1.1 Specification Citations & Invariants
- **`ORIGINAL_REQUEST.md:48`**:
  > "Record in project.json whether the source is cloned or externalBookmark. Store project metadata, cached waveform data, thumbnail caches, and synthesized cue WAVs in the bundle. Never store plain text API keys in the bundle."
- **`ORIGINAL_REQUEST.md:97`**:
  > "7. Security Suite: Asserts cloud API keys round-trip through macOS Keychain (kSecClassGenericPassword) and project.json contains no plaintext credentials."
- **`ORIGINAL_REQUEST.md:123`**:
  > "API keys for ElevenLabs, Resemble, and Gemini are stored exclusively in macOS Keychain."
- **`PROJECT.md:40`**:
  > "16 | Keychain Credential Vault | Secure storage of API keys via kSecClassGenericPassword | M1 | R3, R5, AC 123"
- **`PROJECT.md:117, 181-182`**:
  > File layout mandates:
  > `Sources/AmendCore/Storage/KeychainVault.swift`
  > `Tests/AmendCoreTests/Suites/SecuritySuiteTests.swift`
  > `Tests/AmendCoreTests/Suites/StorageAPFSTests.swift`
- **`spec_miner_fixtures_0/handoff.md:13`**:
  > "Security Suite | macOS Keychain round-trip validation and project bundle AST credential leak scanner. | Service keys (ElevenLabs, Resemble, Gemini), project bundle directory URL. | Keychain CRUD success, zero plaintext key matches in bundle JSON. | Keychain OSStatus error or regex match of API key in project.json fails test."
- **`spec_miner_fixtures_0/handoff.md:50-51`**:
  > Edge cases #17 and #18:
  > - "Keychain item already exists during save: System performs SecItemUpdate instead of failing with errSecDuplicateItem."
  > - "Project bundle exported / packaged into zip: Verify zip archive and internal project.json contain no API keys, secrets, or user home directory absolute paths."

### 1.2 Tool Observations & Runtime Verifications
1. **Swift Version & Environment**:
   - Running `swift --version` on the host returned:
     `Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1) Target: arm64-apple-macosx26.0`.
2. **CoreMedia Codable Gap**:
   - Running `swift -e 'import CoreMedia; struct Foo: Codable { let t: CMTime }'` resulted in:
     `error: type 'Foo' does not conform to protocol 'Decodable' ... cannot automatically synthesize 'Decodable' because 'CMTime' does not conform to 'Decodable'`.
   - Verified that `CMTime` and `CMTimeRange` require `@retroactive Codable` extensions preserving exact rational fields (`value: Int64`, `timescale: Int32`, `flags: UInt32`, `epoch: Int64` and `start`, `duration`). Tested and confirmed lossless round-trip.
3. **Keychain Services Behavior**:
   - Tested `SecItemAdd`, `SecItemCopyMatching`, `SecItemUpdate`, and `SecItemDelete` with `kSecClassGenericPassword` via command execution on macOS 14+. All operations completed with `OSStatus = 0` (`errSecSuccess`) without GUI prompts or sandboxing blocks in CLI/test mode.
   - Tested duplicate insertion: when item already exists, `SecItemAdd` returns `errSecDuplicateItem` (-25299). Handling this by falling back to `SecItemUpdate` succeeded cleanly.
   - Tested existence check: `SecItemCopyMatching(query, nil)` (omitting `kSecReturnData`) returns `errSecSuccess` (0) when present and `errSecItemNotFound` (-25300) when absent, avoiding secret copying into memory.
4. **AST / Credential Leak Scanner Behavior**:
   - Tested JSON recursive traversal and regex pattern matching. Verified that regex patterns must account for provider prefixes, underscores, and hyphens (e.g. `sk_[a-zA-Z0-9_\-]{20,}` for ElevenLabs and `AIza[0-9A-Za-z_\-]{35}` for Gemini).
   - Confirmed detection of suspicious JSON keys (`api_key`, `secret`, `token`, `password`, `auth`) and absolute user home directory paths (`/Users/[^/]+/`).

---

## 2. Logic Chain

### 2.1 Keychain Credential Vault Design Logic
1. *From R5, AC 123, and Edge Case 17*: Cloud TTS synthesis (ElevenLabs, Resemble, Gemini) requires API credentials. Storing credentials in plain text in config files or project bundles risks unauthorized credential exposure. Therefore, credentials must reside exclusively in the macOS Keychain using `kSecClassGenericPassword`.
2. *From Service Key Requirements*: The system explicitly supports three providers:
   - ElevenLabs (`ServiceKey.elevenLabs`)
   - Resemble (`ServiceKey.resemble`)
   - Gemini (`ServiceKey.gemini`)
   Defining a typed, case-iterable enum `ServiceKey: String, CaseIterable, Sendable, Codable` eliminates stringly-typed bugs and allows automated iteration in test suites.
3. *From Keychain API Concurrency & Test Isolation*:
   - Default service identifier: `"com.fady.amend.credentials"`.
   - `KeychainVault` must support an injectable `serviceIdentifier: String` parameter in its initializer. This ensures unit tests can run against an isolated domain (e.g. `"com.fady.amend.credentials.tests"`) and clean up completely in `tearDown()` without wiping real user credentials.
   - A `CredentialVaultProtocol` abstraction allows `MockCredentialVault` in-memory substitution for CI, preview, and isolated component testing.
4. *From SecItem Error & Duplicate Handling Logic*:
   - When saving an existing key, calling `SecItemAdd` will return `errSecDuplicateItem` (-25299). Rather than failing, `save(key:for:)` catches this status and immediately calls `SecItemUpdate` with the existing query keys (`kSecClass`, `kSecAttrService`, `kSecAttrAccount`) and new attributes (`[kSecValueData: keyData]`).
   - `get(keyFor:)` returns `nil` when `SecItemCopyMatching` returns `errSecItemNotFound` (-25300), throwing a typed `KeychainVaultError` only on unexpected OS errors.
   - `delete(keyFor:)` treats `errSecItemNotFound` as a success (idempotent deletion).
   - `has(keyFor:)` executes `SecItemCopyMatching` without `kSecReturnData: true`, checking for `errSecSuccess`.

### 2.2 Project Bundle AST & Credential Leak Scanner Logic
1. *From R3, AC 123, and Edge Case 18*: Project bundles (`.amend`) contain `project.json`, audio WAVs, thumbnail images, and waveform cache files. A project bundle must be completely self-contained and shareable without exposing the creator's API keys or personal home directory paths.
2. *From Defense-in-Depth Principle*: Relying solely on developers "remembering" not to serialize credentials is insufficient. An automated scanner (`CredentialLeakScanner`) must verify bundle contents:
   - **AST Traversal**: Recursively walk `project.json` JSON structure. Any key containing `api_key`, `secret`, `token`, `password`, `auth`, `bearer` with non-trivial values must trigger a violation.
   - **Pattern Matching**: Regex scan text/json files against known provider formats:
     - ElevenLabs: `(?i)sk_[a-zA-Z0-9_\-]{20,}` and `(?i)eleven_[a-zA-Z0-9_\-]{20,}`
     - Google / Gemini: `AIza[0-9A-Za-z_\-]{35}`
     - Resemble: `(?i)resemble_[a-zA-Z0-9_\-]{20,}`
     - Generic Tokens: `(?i)bearer\s+[a-zA-Z0-9_\-\.]{20,}`
   - **Known Secret Cross-Check**: Accept a list of active secrets from Keychain and assert that none appear anywhere in bundle files.
   - **Absolute Path Check**: Detect `/Users/[^/]+/` or `/home/[^/]+/` in `project.json`. Bundle paths must be relative, while foreign media must use security-scoped bookmarks.
3. *From Worker Implementation Efficiency*: The scanner should be implemented in `Sources/AmendCore/Storage/CredentialLeakScanner.swift` and tested in `Tests/AmendCoreTests/Suites/SecuritySuiteTests.swift`.

### 2.3 Milestone 1 Unit Test Suite Design Logic
1. *From PROJECT.md and spec_miner_fixtures_0*: Milestone 1 introduces two core test suites:
   - `StorageAPFSTests.swift`: Validates APFS copyItem cloning, bookmark fallback for cross-volume media, and lossless `project.json` serialization round-trips.
   - `SecuritySuiteTests.swift`: Validates Keychain CRUD lifecycle, duplicate handling, idempotent deletion, and the credential leak scanner against clean and adversarial bundles.
2. *From Invariant Rigor*:
   - All `CMTime` and `CMTimeRange` assertions in tests must use `CMTimeCompare(t1, t2) == 0`. Floating-point comparisons (`cmTime.seconds == ...`) are strictly prohibited.
   - Test suites must clean up all temporary directories, bundles, and Keychain test items in `tearDown()`.

---

## 3. Detailed Technical Recommendations

### 3.1 Component 1: Keychain Credential Vault (`KeychainVault.swift`)

#### Source Path
`Sources/AmendCore/Storage/KeychainVault.swift`

#### Protocol & Types
```swift
import Foundation
import Security

public enum ServiceKey: String, CaseIterable, Sendable, Codable {
    case elevenLabs = "ElevenLabs"
    case resemble = "Resemble"
    case gemini = "Gemini"
}

public protocol CredentialVaultProtocol: Sendable {
    func save(key: String, for service: ServiceKey) throws
    func get(keyFor service: ServiceKey) throws -> String?
    func delete(keyFor service: ServiceKey) throws
    func has(keyFor service: ServiceKey) -> Bool
}

public enum KeychainVaultError: LocalizedError, Equatable {
    case duplicateItem
    case itemNotFound
    case unhandledStatus(OSStatus)
    case dataConversionError
    case invalidInput(String)
    
    public var errorDescription: String? {
        switch self {
        case .duplicateItem:
            return "Item already exists in Keychain."
        case .itemNotFound:
            return "Item not found in Keychain."
        case .unhandledStatus(let status):
            return "Keychain error: OSStatus \(status) - \(SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error")"
        case .dataConversionError:
            return "Failed to convert Keychain data to UTF-8 string."
        case .invalidInput(let reason):
            return "Invalid credential input: \(reason)"
        }
    }
}
```

#### Class Implementation
```swift
public final class KeychainVault: CredentialVaultProtocol, @unchecked Sendable {
    public let serviceIdentifier: String
    private let accessGroup: String?

    public init(serviceIdentifier: String = "com.fady.amend.credentials", accessGroup: String? = nil) {
        self.serviceIdentifier = serviceIdentifier
        self.accessGroup = accessGroup
    }

    public func save(key: String, for service: ServiceKey) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KeychainVaultError.invalidInput("API key cannot be empty or whitespace.")
        }
        guard let keyData = trimmed.data(using: .utf8) else {
            throw KeychainVaultError.dataConversionError
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: service.rawValue,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Update existing entry
            var updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceIdentifier,
                kSecAttrAccount as String: service.rawValue
            ]
            if let accessGroup = accessGroup {
                updateQuery[kSecAttrAccessGroup as String] = accessGroup
            }

            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: keyData
            ]

            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributesToUpdate as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainVaultError.unhandledStatus(updateStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainVaultError.unhandledStatus(status)
        }
    }

    public func get(keyFor service: ServiceKey) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: service.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainVaultError.unhandledStatus(status)
        }
        guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
            throw KeychainVaultError.dataConversionError
        }
        return string
    }

    public func delete(keyFor service: ServiceKey) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: service.rawValue
        ]
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainVaultError.unhandledStatus(status)
        }
    }

    public func has(keyFor service: ServiceKey) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: service.rawValue,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }
}
```

#### In-Memory Mock (`MockCredentialVault.swift`)
```swift
public final class MockCredentialVault: CredentialVaultProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ServiceKey: String] = [:]

    public init(initialValues: [ServiceKey: String] = [:]) {
        self.storage = initialValues
    }

    public func save(key: String, for service: ServiceKey) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KeychainVaultError.invalidInput("API key cannot be empty.")
        }
        lock.lock()
        defer { lock.unlock() }
        storage[service] = trimmed
    }

    public func get(keyFor service: ServiceKey) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[service]
    }

    public func delete(keyFor service: ServiceKey) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: service)
    }

    public func has(keyFor service: ServiceKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage[service] != nil
    }
}
```

---

### 3.2 Component 2: Project Bundle AST / Credential Leak Scanner (`CredentialLeakScanner.swift`)

#### Source Path
`Sources/AmendCore/Storage/CredentialLeakScanner.swift`

#### Types & Implementation
```swift
import Foundation

public struct LeakViolation: Equatable, Sendable, CustomStringConvertible {
    public enum Rule: String, Sendable {
        case knownSecretMatch = "Known Secret Detected"
        case providerPatternMatch = "Cloud Provider Key Pattern Match"
        case suspiciousKeyInAST = "Suspicious Key Name in JSON AST"
        case absoluteUserPath = "User Absolute Path Detected"
    }

    public let rule: Rule
    public let fileRelativePath: String
    public let contextSnippet: String
    public let astPath: String?

    public var description: String {
        let pathStr = astPath != nil ? " at '\(astPath!)'" : ""
        return "[\(rule.rawValue)] in \(fileRelativePath)\(pathStr): \(contextSnippet)"
    }
}

public protocol CredentialLeakScanning: Sendable {
    func scan(bundleURL: URL, knownSecrets: [String]) throws -> [LeakViolation]
    func scan(projectJSONData: Data, knownSecrets: [String]) throws -> [LeakViolation]
}

public final class CredentialLeakScanner: CredentialLeakScanning {
    public static let shared = CredentialLeakScanner()

    // Compiled regex patterns
    private let providerPatterns: [NSRegularExpression] = [
        // ElevenLabs sk_... or 32-hex
        try! NSRegularExpression(pattern: "(?i)\\b(?:sk_)?[a-f0-9]{32}\\b"),
        try! NSRegularExpression(pattern: "(?i)\\bsk_[a-zA-Z0-9_\\-]{20,}\\b"),
        // Google / Gemini AIza...
        try! NSRegularExpression(pattern: "\\bAIza[0-9A-Za-z_\\-]{35}\\b"),
        // Resemble AI resemble_...
        try! NSRegularExpression(pattern: "(?i)\\bresemble_[a-zA-Z0-9_\\-]{20,}\\b"),
        // Bearer tokens
        try! NSRegularExpression(pattern: "(?i)\\bbearer\\s+[a-zA-Z0-9_\\-\\.\\=]{20,}\\b")
    ]

    private let suspiciousKeyPattern = try! NSRegularExpression(pattern: "(?i)^(api[_-]?key|secret|token|password|auth_header|bearer|credentials)$")
    private let userAbsolutePathPattern = try! NSRegularExpression(pattern: "/(?:Users|home)/[A-Za-z0-9._\\-]+/")

    public init() {}

    public func scan(projectJSONData: Data, knownSecrets: [String] = []) throws -> [LeakViolation] {
        var violations: [LeakViolation] = []

        // 1. Raw text pattern and known secret check
        guard let jsonString = String(data: projectJSONData, encoding: .utf8) else {
            throw NSError(domain: "CredentialLeakScanner", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8 project.json data"])
        }
        scanText(jsonString, relativePath: "project.json", knownSecrets: knownSecrets, violations: &violations)

        // 2. JSON AST Traversal
        if let jsonObject = try? JSONSerialization.jsonObject(with: projectJSONData, options: []) {
            walkJSONAST(node: jsonObject, currentPath: "$", relativePath: "project.json", knownSecrets: knownSecrets, violations: &violations)
        }

        return violations
    }

    public func scan(bundleURL: URL, knownSecrets: [String] = []) throws -> [LeakViolation] {
        var violations: [LeakViolation] = []
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(at: bundleURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return violations
        }

        for case let fileURL as URL in enumerator {
            let relativePath = fileURL.path.replacingOccurrences(of: bundleURL.path + "/", with: "")
            let ext = fileURL.pathExtension.lowercased()

            // Skip binary media files
            if ["mov", "mp4", "wav", "m4a", "png", "jpg", "jpeg", "bin"].contains(ext) {
                continue
            }

            if relativePath == "project.json" {
                let data = try Data(contentsOf: fileURL)
                let subViolations = try scan(projectJSONData: data, knownSecrets: knownSecrets)
                violations.append(contentsOf: subViolations)
            } else if ["json", "txt", "plist", "xml", "log", "yaml", "yml"].contains(ext) {
                if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
                    scanText(text, relativePath: relativePath, knownSecrets: knownSecrets, violations: &violations)
                }
            }
        }

        return violations
    }

    private func scanText(_ text: String, relativePath: String, knownSecrets: [String], violations: inout [LeakViolation]) {
        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        // Known secrets match
        for secret in knownSecrets where secret.count >= 8 {
            if text.contains(secret) {
                let snippet = String(secret.prefix(4)) + "..." + String(secret.suffix(4))
                violations.append(LeakViolation(rule: .knownSecretMatch, fileRelativePath: relativePath, contextSnippet: snippet, astPath: nil))
            }
        }

        // Provider regex patterns
        for regex in providerPatterns {
            let matches = regex.matches(in: text, options: [], range: fullRange)
            for match in matches {
                let matchedString = nsString.substring(with: match.range)
                let snippet = String(matchedString.prefix(6)) + "..." + String(matchedString.suffix(4))
                violations.append(LeakViolation(rule: .providerPatternMatch, fileRelativePath: relativePath, contextSnippet: snippet, astPath: nil))
            }
        }
    }

    private func walkJSONAST(node: Any, currentPath: String, relativePath: String, knownSecrets: [String], violations: inout [LeakViolation]) {
        if let dict = node as? [String: Any] {
            for (key, value) in dict {
                let nextPath = "\(currentPath).\(key)"
                let keyRange = NSRange(location: 0, length: key.utf16.count)

                // Check suspicious key
                if suspiciousKeyPattern.firstMatch(in: key, options: [], range: keyRange) != nil {
                    // Check if value is non-empty / non-trivial
                    if let strVal = value as? String, !strVal.isEmpty {
                        violations.append(LeakViolation(rule: .suspiciousKeyInAST, fileRelativePath: relativePath, contextSnippet: "Key '\(key)' with non-empty string", astPath: nextPath))
                    } else if !(value is NSNull) {
                        violations.append(LeakViolation(rule: .suspiciousKeyInAST, fileRelativePath: relativePath, contextSnippet: "Key '\(key)' present", astPath: nextPath))
                    }
                }

                walkJSONAST(node: value, currentPath: nextPath, relativePath: relativePath, knownSecrets: knownSecrets, violations: &violations)
            }
        } else if let array = node as? [Any] {
            for (idx, item) in array.enumerated() {
                walkJSONAST(node: item, currentPath: "\(currentPath)[\(idx)]", relativePath: relativePath, knownSecrets: knownSecrets, violations: &violations)
            }
        } else if let str = node as? String {
            // Check absolute user path
            let strRange = NSRange(location: 0, length: str.utf16.count)
            if userAbsolutePathPattern.firstMatch(in: str, options: [], range: strRange) != nil {
                violations.append(LeakViolation(rule: .absoluteUserPath, fileRelativePath: relativePath, contextSnippet: str, astPath: currentPath))
            }
        }
    }
}
```

---

### 3.3 Component 3: Milestone 1 Unit Test Suites

#### Suite 1: `StorageAPFSTests.swift`
**Location**: `Tests/AmendCoreTests/Suites/StorageAPFSTests.swift`

**Test Cases**:
1. `test_apfs_cloning_detected_on_apfs_volume`:
   - Inspects `NSTemporaryDirectory()` using `URLResourceValues.volumeSupportsFileCloning`.
   - Asserts `volumeSupportsFileCloning == true` on macOS Apple Silicon APFS root/data volumes.
2. `test_apfs_copyItem_creates_clone_source_file`:
   - Creates a synthetic 1MB source file `source.mov` in a temporary directory.
   - Executes `APFSCloner.cloneMedia(from: sourceURL, intoBundle: bundleURL)`.
   - Asserts target file exists in bundle at `bundleURL/source.mov`.
   - Asserts file size matches source.
   - Asserts `SourceStorageMode` matches `.cloned(relativePath: "source.mov")`.
3. `test_bookmark_fallback_creation_and_resolution`:
   - Creates a synthetic external media file outside the bundle.
   - Generates security-scoped bookmark:
     `BookmarkManager.createBookmark(for: sourceURL)`
   - Asserts `SourceStorageMode` is `.externalBookmark(bookmarkData: ..., originalPath: ...)`.
   - Resolves bookmark via `BookmarkManager.resolve(bookmarkData: ...)`.
   - Asserts resolved URL exists and targets the source file.
4. `test_project_metadata_serialization_roundtrip`:
   - Builds `ProjectMetadata` with `totalDuration: CMTime(value: 9000, timescale: 600)`, `sourceStorageMode: .cloned(relativePath: "source.mov")`, track IDs, UUID, dates.
   - Encodes with `JSONEncoder()`.
   - Decodes with `JSONDecoder()`.
   - Asserts exact equality across all fields, including `CMTimeCompare(original.totalDuration, decoded.totalDuration) == 0`.
5. `test_cue_cmtimerange_codable_rational_precision`:
   - Creates `Cue` array with varied timescales (e.g. 48,000 for audio, 600 for video).
   - Verifies round-trip preserves exact numerator and denominator without floating-point accumulation or round-off.
6. `test_project_bundle_directory_scaffolding`:
   - Instantiates `ProjectBundle.create(at: bundleURL, metadata: metadata)`.
   - Asserts directory structure:
     `project.json`, `waveforms/`, `thumbnails/`, `audio/`.

#### Suite 2: `SecuritySuiteTests.swift`
**Location**: `Tests/AmendCoreTests/Suites/SecuritySuiteTests.swift`

**Test Cases**:
1. `test_keychain_crud_all_supported_services`:
   - Uses test service identifier `"com.fady.amend.tests.credentials"`.
   - Iterates through `ServiceKey.allCases` (`.elevenLabs`, `.resemble`, `.gemini`).
   - For each:
     - `vault.save(key: "secret_val", for: service)`
     - Asserts `vault.has(keyFor: service) == true`
     - Asserts `vault.get(keyFor: service) == "secret_val"`
     - `vault.delete(keyFor: service)`
     - Asserts `vault.has(keyFor: service) == false`
     - Asserts `vault.get(keyFor: service) == nil`
2. `test_keychain_update_existing_item_without_duplicate_error`:
   - Saves initial secret for `.elevenLabs`.
   - Saves new secret for `.elevenLabs`.
   - Asserts no exception thrown (verifies `SecItemUpdate` path when `errSecDuplicateItem` is received).
   - Asserts retrieved value equals new secret.
3. `test_keychain_empty_key_rejected`:
   - Asserts saving `""` or `"   "` throws `KeychainVaultError.invalidInput`.
4. `test_keychain_delete_idempotent`:
   - Deleting a key not currently in Keychain succeeds without throwing.
5. `test_credential_leak_scanner_clean_bundle_passes`:
   - Scans valid project bundle and valid `project.json`.
   - Asserts `violations.isEmpty == true`.
6. `test_credential_leak_scanner_detects_elevenlabs_key`:
   - Injects `"sk_test_1234567890abcdef1234567890abcdef"` into `project.json`.
   - Asserts violation reported with `.providerPatternMatch` or `.suspiciousKeyInAST`.
7. `test_credential_leak_scanner_detects_gemini_key`:
   - Injects `"AIzaSyD-abc1234567890123456789012345678"` into cue transcript.
   - Asserts violation reported with `.providerPatternMatch`.
8. `test_credential_leak_scanner_detects_known_secret_in_any_bundle_file`:
   - Adds custom secret `"arbitrary_secret_token_12345"` to `knownSecrets`.
   - Injects string into `debug.log` in `.amend` bundle.
   - Asserts violation reported with `.knownSecretMatch`.
9. `test_credential_leak_scanner_detects_user_absolute_paths`:
   - Injects `"/Users/fady/Movies/test.mov"` into `project.json`.
   - Asserts violation reported with `.absoluteUserPath`.

---

## 4. Caveats
1. **Keychain Access in CI / Headless Environments**:
   - On macOS developer machines, `SecItemAdd` with `kSecClassGenericPassword` works immediately without GUI prompts.
   - On headless CI runners (e.g. GitHub Actions macOS runners), the login keychain might be locked by default unless `security unlock-keychain` is invoked. Providing `MockCredentialVault` ensures unit tests can run anywhere without requiring OS keychain unlocks if desired.
2. **APFS Cloning Across Partitions**:
   - `FileManager.copyItem` on APFS is an instant copy-on-write operation only when source and destination are on the same APFS volume container. If a source file is on an external drive or network share, `volumeSupportsFileCloning` returns `false`, and amend must fall back to a security-scoped bookmark without copying the multi-gigabyte file.
3. **CoreMedia Codable Retroactivity**:
   - Because `CMTime` is an Apple C-struct, marking it `@retroactive Codable` is standard in Swift 6. This extension should reside in `AmendCore/Models/CMTime+Codable.swift` to make it accessible to all core models.

---

## 5. Conclusion
The Security Credential Vault (`KeychainVault`), Project Bundle AST / Credential Leak Scanner (`CredentialLeakScanner`), and Milestone 1 Unit Test Suites (`StorageAPFSTests` and `SecuritySuiteTests`) have been thoroughly designed and verified against macOS 14+ APIs and the Swift 6 toolchain. All edge cases (duplicate updates, idempotent deletion, multi-layer AST regex scanning, rational CMTime Codable preservation) have concrete, verified specifications ready for implementation by the Worker agent.

---

## 6. Verification Method
1. Inspect the handoff report at:
   `/Users/fady/Dev/amend/.agents/m1_explorer_3/handoff.md`
2. Validate Keychain CRUD and leak scanner behavior with:
   ```bash
   swift test --filter SecuritySuiteTests
   ```
3. Validate APFS cloning, bookmark fallback, and project.json serialization with:
   ```bash
   swift test --filter StorageAPFSTests
   ```
4. Verify that zero plaintext API keys leak into any `.amend` project bundle.
