import Foundation
import CoreMedia
import MacDubCore

var passedCount = 0
var failedCount = 0

func assertTest(_ condition: Bool, _ message: String) {
    if condition {
        passedCount += 1
        print("  [PASS] \(message)")
    } else {
        failedCount += 1
        print("  [FAIL] \(message)")
    }
}

print("=== MACDUB ADVERSARIAL STRESS TEST SUITE ===")

// MARK: - 1. CMTime & CMTimeRange Precision
print("\n--- Suite 1: CMTime+Codable Rational Precision & Boundary Invariants ---")

let testTimes: [(Int64, Int32, UInt32, Int64, String)] = [
    (0, 48000, 1, 0, "Zero time at 48kHz"),
    (1, 48000, 1, 0, "1 sample at 48kHz"),
    (123456789012345, 600, 1, 0, "Large Int64 timestamp at 600 scale"),
    (Int64.max - 100, 1000, 1, 0, "Near max Int64"),
    (1001, 30000, 1, 0, "29.97 NTSC frame unit"),
    (48000, 48000, 1, 0, "Exactly 1 second audio"),
    (96000, 48000, 1, 0, "Exactly 2 seconds audio")
]

for (val, scale, flags, epoch, name) in testTimes {
    let t = CMTime(value: val, timescale: scale, flags: CMTimeFlags(rawValue: flags), epoch: epoch)
    do {
        let data = try JSONEncoder().encode(t)
        let decoded = try JSONDecoder().decode(CMTime.self, from: data)
        let exactMatch = decoded.value == val && decoded.timescale == scale && decoded.flags.rawValue == flags && decoded.epoch == epoch
        let cmCompareMatch = CMTimeCompare(t, decoded) == 0
        assertTest(exactMatch && cmCompareMatch, "\(name): exact integer preservation (\(val)/\(scale))")
    } catch {
        assertTest(false, "\(name): threw error \(error)")
    }
}

// CMTimeRange tests
let r1 = CMTimeRange(start: CMTime(value: 100, timescale: 48000), duration: CMTime(value: 200, timescale: 48000))
do {
    let data = try JSONEncoder().encode(r1)
    let decoded = try JSONDecoder().decode(CMTimeRange.self, from: data)
    assertTest(decoded.start.value == 100 && decoded.duration.value == 200, "CMTimeRange exact rational preservation")
} catch {
    assertTest(false, "CMTimeRange decode threw error: \(error)")
}

// MARK: - 2. CredentialLeakScanner Matrix
print("\n--- Suite 2: CredentialLeakScanner Matrix & False Positive / False Negative Stress ---")
let scanner = CredentialLeakScanner.shared

// Test 2.1: Known secret in nested JSON
let secret1 = "super_secret_elevenlabs_token_9999"
let nestedJSON = """
{
    "id": "\(UUID().uuidString)",
    "name": "NestedSecret",
    "config": {
        "items": [
            { "deep_note": "Here is token: \(secret1)" }
        ]
    }
}
""".data(using: .utf8)!

do {
    let v = try scanner.scan(projectJSONData: nestedJSON, knownSecrets: [secret1])
    assertTest(v.contains { $0.rule == .knownSecretMatch }, "Detects known secret in deeply nested JSON")
} catch {
    assertTest(false, "Nested JSON scan threw: \(error)")
}

// Test 2.2: User home directory detection (/Users/ and /home/)
let userPathJSON = """
{
    "id": "\(UUID().uuidString)",
    "mac_path": "/Users/developer/recordings/test.mp4",
    "linux_path": "/home/ubuntu/recordings/test.mp4",
    "safe_system_path": "/System/Library/Fonts/Helvetica.ttc",
    "safe_app_path": "/Applications/MacDub.app/Contents/MacOS/macdub"
}
""".data(using: .utf8)!

do {
    let v = try scanner.scan(projectJSONData: userPathJSON, knownSecrets: [])
    let userPaths = v.filter { $0.rule == .absoluteUserPath }
    assertTest(userPaths.count == 2, "Detects both /Users/ and /home/ paths (found \(userPaths.count))")
    let hasFalsePositives = v.contains { $0.contextSnippet.contains("/System/") || $0.contextSnippet.contains("/Applications/") }
    assertTest(!hasFalsePositives, "Zero false positives on /System/ or /Applications/ paths")
} catch {
    assertTest(false, "Path scan threw: \(error)")
}

// Test 2.3: Suspicious keys in AST
let suspiciousKeyJSON = """
{
    "id": "\(UUID().uuidString)",
    "api_key": "some_value",
    "auth_header": "some_header",
    "secret": "hidden_value",
    "token": "tok_12345"
}
""".data(using: .utf8)!

do {
    let v = try scanner.scan(projectJSONData: suspiciousKeyJSON, knownSecrets: [])
    let astViolations = v.filter { $0.rule == .suspiciousKeyInAST }
    assertTest(astViolations.count >= 4, "Detects suspicious AST keys (api_key, auth_header, secret, token), count: \(astViolations.count)")
} catch {
    assertTest(false, "Suspicious key scan threw: \(error)")
}

// Test 2.4: Clean project.json with audio cue text that discusses API concepts without leaking
let cleanTechDiscussionJSON = """
{
    "id": "\(UUID().uuidString)",
    "name": "DevTutorial",
    "sourceStorageMode": { "cloned": { "relativePath": "source.mp4" } },
    "designatedNarrationTrackID": 1,
    "totalDuration": { "value": 3000, "timescale": 600, "flags": 1, "epoch": 0 },
    "cues": [
        {
            "id": "\(UUID().uuidString)",
            "timeRange": { "start": { "value": 0, "timescale": 600, "flags": 1, "epoch": 0 }, "duration": { "value": 3000, "timescale": 600, "flags": 1, "epoch": 0 } },
            "text": "Today we talk about how to protect your API keys using macOS Keychain vault.",
            "originalText": "Today we talk about how to protect your API keys using macOS Keychain vault.",
            "editState": "original"
        }
    ]
}
""".data(using: .utf8)!

do {
    let v = try scanner.scan(projectJSONData: cleanTechDiscussionJSON, knownSecrets: [])
    assertTest(v.isEmpty, "Narration discussing 'API keys' does not trigger false positive in clean project.json (violations: \(v))")
} catch {
    assertTest(false, "Clean tech discussion scan threw: \(error)")
}

// MARK: - 3. KeychainVault Concurrency & Character Sets
print("\n--- Suite 3: KeychainVault Rapid Updates, Character Sets & Invariants ---")
let testVaultID = "com.macdub.tests.adversarial.\(UUID().uuidString)"
let testVault = KeychainVault(serviceIdentifier: testVaultID)

defer {
    for s in ServiceKey.allCases {
        try? testVault.delete(keyFor: s)
    }
}

// 3.1 Unicode and complex characters
let complexKey = "sk_test_🔥_1234_äöü_!@#$%^&*()_+~`|}{[]:;?><,./"
do {
    try testVault.save(key: complexKey, for: .resemble)
    let fetched = try testVault.get(keyFor: .resemble)
    assertTest(fetched == complexKey, "Keychain stores and retrieves complex Unicode / symbol secret exactly")
} catch {
    assertTest(false, "Keychain complex character test threw: \(error)")
}

// 3.2 Rapid sequential updates
var updateSuccess = true
for i in 1...10 {
    do {
        try testVault.save(key: "secret_iteration_\(i)", for: .gemini)
        let val = try testVault.get(keyFor: .gemini)
        if val != "secret_iteration_\(i)" {
            updateSuccess = false
        }
    } catch {
        updateSuccess = false
        break
    }
}
assertTest(updateSuccess, "Rapid sequential updates to KeychainVault succeed without duplicate item error")

// MARK: - 4. ProjectBundle Directory Scaffolding & Atomic Writes
print("\n--- Suite 4: ProjectBundle Directory Scaffolding & Atomicity ---")
let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent("MacDubAdvTest_\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: tempBase)
}

let bundlePath = tempBase.appendingPathComponent("AutoExtensionTest") // No .voicefix suffix
let meta = ProjectMetadata(
    name: "AutoExtensionTest",
    sourceStorageMode: .cloned(relativePath: "source.mp4"),
    designatedNarrationTrackID: 1,
    totalDuration: CMTime(value: 1000, timescale: 600)
)

do {
    let b = try ProjectBundle.create(at: bundlePath, metadata: meta)
    assertTest(b.rootURL.pathExtension == "voicefix", "ProjectBundle.create automatically appends .voicefix extension if omitted")
    assertTest(FileManager.default.fileExists(atPath: b.projectJSONURL.path), "project.json exists at bundle root")
    assertTest(FileManager.default.fileExists(atPath: b.cuesAudioDirectoryURL.path), "audio/cues subdirectory scaffolded")
    assertTest(FileManager.default.fileExists(atPath: b.waveformsDirectoryURL.path), "waveforms subdirectory scaffolded")
    assertTest(FileManager.default.fileExists(atPath: b.thumbnailsDirectoryURL.path), "thumbnails subdirectory scaffolded")

    // Verify atomic save updates
    var updatedMeta = b.metadata
    updatedMeta.name = "RenamedProject"
    var updatedBundle = b
    updatedBundle.metadata = updatedMeta
    try ProjectBundleSerializer.save(bundle: updatedBundle)

    let reloaded = try ProjectBundleSerializer.load(from: b.rootURL)
    assertTest(reloaded.metadata.name == "RenamedProject", "ProjectBundleSerializer.save writes atomically and reloads updated metadata")
} catch {
    assertTest(false, "Bundle creation threw: \(error)")
}

print("\n=== SUMMARY ===")
print("Passed: \(passedCount), Failed: \(failedCount)")
if failedCount == 0 {
    print("ALL ADVERSARIAL CHECKS PASSED!")
    exit(0)
} else {
    print("SOME CHECKS FAILED!")
    exit(1)
}
