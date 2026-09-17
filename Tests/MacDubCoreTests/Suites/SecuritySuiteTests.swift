import Testing
import Foundation
import CoreMedia
@testable import MacDubCore

@Suite("Security Suite Tests")
final class SecuritySuiteTests {
    private let testServiceIdentifier: String
    private let vault: KeychainVault
    private let tempDirectory: URL

    init() throws {
        self.testServiceIdentifier = "com.macdub.tests.credentials.\(UUID().uuidString)"
        self.vault = KeychainVault(serviceIdentifier: testServiceIdentifier)

        let uniqueID = UUID().uuidString
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDubSecurityTests_\(uniqueID)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    deinit {
        for service in ServiceKey.allCases {
            try? vault.delete(keyFor: service)
        }
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - Keychain Tests

    @Test("Keychain CRUD all supported services")
    func test_keychain_crud_all_supported_services() throws {
        for service in ServiceKey.allCases {
            let secret = "secret_token_\(service.rawValue)_test123"

            // 1. Initially absent
            #expect(!vault.has(keyFor: service))
            #expect(try vault.get(keyFor: service) == nil)

            // 2. Save
            try vault.save(key: secret, for: service)
            #expect(vault.has(keyFor: service))
            #expect(try vault.get(keyFor: service) == secret)

            // 3. Delete
            try vault.delete(keyFor: service)
            #expect(!vault.has(keyFor: service))
            #expect(try vault.get(keyFor: service) == nil)
        }
    }

    @Test("Keychain update existing item without duplicate error")
    func test_keychain_update_existing_item_without_duplicate_error() throws {
        let service = ServiceKey.elevenLabs
        let secret1 = "initial_secret_key_12345"
        let secret2 = "updated_secret_key_67890"

        // First save
        try vault.save(key: secret1, for: service)
        #expect(try vault.get(keyFor: service) == secret1)

        // Second save for same service -> should trigger SecItemUpdate
        try vault.save(key: secret2, for: service)
        #expect(try vault.get(keyFor: service) == secret2)
    }

    @Test("Keychain empty key rejected")
    func test_keychain_empty_key_rejected() {
        #expect {
            try vault.save(key: "", for: .gemini)
        } throws: { error in
            guard case KeychainVaultError.invalidInput = error else { return false }
            return true
        }

        #expect {
            try vault.save(key: "   \n\t  ", for: .resemble)
        } throws: { error in
            guard case KeychainVaultError.invalidInput = error else { return false }
            return true
        }
    }

    @Test("Keychain delete idempotent")
    func test_keychain_delete_idempotent() {
        // Deleting non-existent key should not throw
        #expect(throws: Never.self) {
            try vault.delete(keyFor: .gemini)
        }
    }

    @Test("Mock credential vault CRUD")
    func test_mock_credential_vault() throws {
        let mock = MockCredentialVault()
        #expect(!mock.has(keyFor: .elevenLabs))

        try mock.save(key: "mock_key_eleven", for: .elevenLabs)
        #expect(mock.has(keyFor: .elevenLabs))
        #expect(try mock.get(keyFor: .elevenLabs) == "mock_key_eleven")

        try mock.delete(keyFor: .elevenLabs)
        #expect(!mock.has(keyFor: .elevenLabs))
        #expect(try mock.get(keyFor: .elevenLabs) == nil)

        #expect {
            try mock.save(key: "  ", for: .gemini)
        } throws: { error in
            guard case KeychainVaultError.invalidInput = error else { return false }
            return true
        }
    }

    // MARK: - Credential Leak Scanner Tests

    @Test("Credential leak scanner clean bundle passes")
    func test_credential_leak_scanner_clean_bundle_passes() throws {
        let metadata = ProjectMetadata(
            name: "Clean Project",
            sourceStorageMode: .cloned(relativePath: "source.mp4"),
            designatedNarrationTrackID: 1,
            totalDuration: CMTime(value: 3000, timescale: 600),
            cues: [
                Cue(
                    timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 3000, timescale: 600)),
                    text: "Clean narration text without any secrets."
                )
            ]
        )

        let bundleURL = tempDirectory.appendingPathComponent("Clean.voicefix")
        let bundle = try ProjectBundle.create(at: bundleURL, metadata: metadata)

        let scanner = CredentialLeakScanner.shared
        let violations = try scanner.scan(bundleURL: bundle.rootURL, knownSecrets: ["some_unrelated_secret_12345"])
        #expect(violations.isEmpty, "Clean bundle must have 0 leak violations. Found: \(violations)")
    }

    @Test("Credential leak scanner detects ElevenLabs key")
    func test_credential_leak_scanner_detects_elevenlabs_key() throws {
        let poisonedJSON = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Poisoned",
            "sourceStorageMode": { "cloned": { "relativePath": "source.mp4" } },
            "designatedNarrationTrackID": 1,
            "totalDuration": { "value": 3000, "timescale": 600, "flags": 1, "epoch": 0 },
            "api_token": "sk_abcdef1234567890abcdef1234567890",
            "cues": []
        }
        """.data(using: .utf8)!

        let scanner = CredentialLeakScanner.shared
        let violations = try scanner.scan(projectJSONData: poisonedJSON, knownSecrets: [])
        #expect(!violations.isEmpty, "Scanner must detect ElevenLabs key pattern or suspicious key")
        let hasPatternOrAST = violations.contains { $0.rule == .providerPatternMatch || $0.rule == .suspiciousKeyInAST }
        #expect(hasPatternOrAST)
    }

    @Test("Credential leak scanner detects Gemini key")
    func test_credential_leak_scanner_detects_gemini_key() throws {
        let geminiKey = "AIzaSyD-abc1234567890123456789012345678"
        let metadata = ProjectMetadata(
            name: "Gemini Leak Project",
            sourceStorageMode: .cloned(relativePath: "source.mp4"),
            designatedNarrationTrackID: 1,
            totalDuration: CMTime(value: 3000, timescale: 600),
            cues: [
                Cue(
                    timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 3000, timescale: 600)),
                    text: "My API key is \(geminiKey)"
                )
            ]
        )

        let encoder = ProjectBundleSerializer.makeEncoder()
        let data = try encoder.encode(metadata)

        let scanner = CredentialLeakScanner.shared
        let violations = try scanner.scan(projectJSONData: data, knownSecrets: [])
        let hasGeminiMatch = violations.contains { $0.rule == .providerPatternMatch }
        #expect(hasGeminiMatch, "Scanner must detect Gemini API key pattern")
    }

    @Test("Credential leak scanner detects known secret in any bundle file")
    func test_credential_leak_scanner_detects_known_secret_in_any_bundle_file() throws {
        let metadata = ProjectMetadata(
            name: "Project With Log",
            sourceStorageMode: .cloned(relativePath: "source.mp4"),
            designatedNarrationTrackID: 1,
            totalDuration: CMTime(value: 3000, timescale: 600)
        )
        let bundleURL = tempDirectory.appendingPathComponent("WithLog.voicefix")
        let bundle = try ProjectBundle.create(at: bundleURL, metadata: metadata)

        let secretToDetect = "confidential_resemble_secret_token_12345"
        let logURL = bundle.rootURL.appendingPathComponent("debug.log")
        try "Log entry with secret: \(secretToDetect)\n".write(to: logURL, atomically: true, encoding: .utf8)

        let scanner = CredentialLeakScanner.shared
        let violations = try scanner.scan(bundleURL: bundle.rootURL, knownSecrets: [secretToDetect])
        let hasSecretMatch = violations.contains { $0.rule == .knownSecretMatch }
        #expect(hasSecretMatch, "Scanner must detect known secret in debug.log")
    }

    @Test("Credential leak scanner detects user absolute paths")
    func test_credential_leak_scanner_detects_user_absolute_paths() throws {
        let poisonedJSON = """
        {
            "id": "\(UUID().uuidString)",
            "name": "UserPathProject",
            "sourceStorageMode": { "cloned": { "relativePath": "source.mp4" } },
            "designatedNarrationTrackID": 1,
            "totalDuration": { "value": 3000, "timescale": 600, "flags": 1, "epoch": 0 },
            "sourceOriginalPath": "/Users/developer/Movies/secret_recording.mov",
            "cues": []
        }
        """.data(using: .utf8)!

        let scanner = CredentialLeakScanner.shared
        let violations = try scanner.scan(projectJSONData: poisonedJSON, knownSecrets: [])
        let hasPathViolation = violations.contains { $0.rule == .absoluteUserPath }
        #expect(hasPathViolation, "Scanner must detect user absolute home path")
    }
}
