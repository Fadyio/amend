import Testing
import Foundation
import CoreMedia
@testable import MacDubCore

@Suite("Adversarial Stress & Edge Case Tests")
final class AdversarialStressTests {
    private let tempDirectory: URL

    init() throws {
        let uniqueID = UUID().uuidString
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDubAdversarialTests_\(uniqueID)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - 1. APFS Cloning vs Bookmark Fallback Challenges

    @Test("APFS cloning with read-only source file")
    func test_apfs_cloning_readonly_source() throws {
        let sourceURL = tempDirectory.appendingPathComponent("readonly_recording.mp4")
        let testData = "Immutable Read-Only Payload \(UUID().uuidString)".data(using: .utf8)!
        try testData.write(to: sourceURL)

        // Make source file read-only (0o444 = r--r--r--)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: sourceURL.path)

        // Verify source is indeed read-only
        let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o444)

        // Create bundle with read-only source
        let bundleURL = tempDirectory.appendingPathComponent("ReadOnlyBundle.voicefix")
        let bundle = try ProjectBundleSerializer.createBundle(
            at: bundleURL,
            sourceMediaURL: sourceURL,
            name: "ReadOnlySourceProject",
            designatedNarrationTrackID: 1,
            totalDuration: CMTime(value: 1000, timescale: 600)
        )

        let resolvedURL = try ProjectBundleSerializer.resolveSourceMediaURL(for: bundle)
        #expect(FileManager.default.fileExists(atPath: resolvedURL.path))
        let clonedData = try Data(contentsOf: resolvedURL)
        #expect(clonedData == testData)

        // Restore permissions for cleanup
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sourceURL.path)
    }

    @Test("APFS cloning into deeply nested bundle path")
    func test_apfs_cloning_nested_bundle_path() throws {
        let sourceURL = tempDirectory.appendingPathComponent("nested_source.mov")
        let testData = Data(repeating: 0x42, count: 64 * 1024)
        try testData.write(to: sourceURL)

        // Deeply nested bundle path whose ancestor directories do not exist yet
        let nestedBundleURL = tempDirectory
            .appendingPathComponent("depth1")
            .appendingPathComponent("depth2")
            .appendingPathComponent("depth3")
            .appendingPathComponent("NestedProject.voicefix")

        #expect(!FileManager.default.fileExists(atPath: nestedBundleURL.path))

        let bundle = try ProjectBundleSerializer.createBundle(
            at: nestedBundleURL,
            sourceMediaURL: sourceURL,
            name: "DeeplyNestedProject",
            designatedNarrationTrackID: 1,
            totalDuration: CMTime(value: 3000, timescale: 600)
        )

        #expect(FileManager.default.fileExists(atPath: bundle.projectJSONURL.path))
        #expect(FileManager.default.fileExists(atPath: bundle.cuesAudioDirectoryURL.path))
        #expect(FileManager.default.fileExists(atPath: bundle.waveformsDirectoryURL.path))
        #expect(FileManager.default.fileExists(atPath: bundle.thumbnailsDirectoryURL.path))

        let resolvedURL = try ProjectBundleSerializer.resolveSourceMediaURL(for: bundle)
        #expect(FileManager.default.fileExists(atPath: resolvedURL.path))
        let resolvedData = try Data(contentsOf: resolvedURL)
        #expect(resolvedData == testData)
    }

    @Test("APFS copy-on-write mutation independence")
    func test_apfs_cow_mutation_independence() throws {
        let sourceURL = tempDirectory.appendingPathComponent("cow_source.mp4")
        let originalPayload = Data(repeating: 0xAA, count: 512 * 1024) // 512 KB
        try originalPayload.write(to: sourceURL)

        let bundleURL = tempDirectory.appendingPathComponent("CoWProject.voicefix")
        let bundle = try ProjectBundleSerializer.createBundle(
            at: bundleURL,
            sourceMediaURL: sourceURL,
            name: "CoWProject",
            designatedNarrationTrackID: 1,
            totalDuration: CMTime(value: 600, timescale: 30)
        )

        let clonedURL = try ProjectBundleSerializer.resolveSourceMediaURL(for: bundle)
        #expect(try Data(contentsOf: clonedURL) == originalPayload)

        // Mutate source media: overwrite with completely different data
        let modifiedSourcePayload = Data(repeating: 0xBB, count: 1024 * 1024) // 1 MB
        try modifiedSourcePayload.write(to: sourceURL)

        // Verify cloned file remains unchanged (true CoW independence)
        let clonedDataAfterSourceMutation = try Data(contentsOf: clonedURL)
        #expect(clonedDataAfterSourceMutation == originalPayload)
        #expect(clonedDataAfterSourceMutation != modifiedSourcePayload)

        // Mutate cloned file: overwrite with a third pattern
        let modifiedClonePayload = Data(repeating: 0xCC, count: 256 * 1024)
        try modifiedClonePayload.write(to: clonedURL)

        // Verify source file remains unchanged by clone mutation
        let sourceDataAfterCloneMutation = try Data(contentsOf: sourceURL)
        #expect(sourceDataAfterCloneMutation == modifiedSourcePayload)
        #expect(sourceDataAfterCloneMutation != modifiedClonePayload)
    }

    @Test("APFS cloning with special characters and spaces in filename")
    func test_apfs_cloning_special_characters_filename() throws {
        let specialName = "screen recording #1 [final] (1080p) ✨.mov"
        let sourceURL = tempDirectory.appendingPathComponent(specialName)
        let dummyData = "Special Char Media Payload".data(using: .utf8)!
        try dummyData.write(to: sourceURL)

        let bundleURL = tempDirectory.appendingPathComponent("Special Project [Alpha] ✨.voicefix")
        let bundle = try ProjectBundleSerializer.createBundle(
            at: bundleURL,
            sourceMediaURL: sourceURL,
            name: "Special Project [Alpha] ✨",
            designatedNarrationTrackID: 1,
            totalDuration: CMTime(value: 1200, timescale: 600)
        )

        let resolvedURL = try ProjectBundleSerializer.resolveSourceMediaURL(for: bundle)
        #expect(FileManager.default.fileExists(atPath: resolvedURL.path))
        #expect(try Data(contentsOf: resolvedURL) == dummyData)
    }

    // MARK: - 2. Atomic Serialization & Concurrency Challenges

    @Test("Atomic serialization prevents partial or corrupt reads under concurrency")
    func test_atomic_serialization_concurrent_reads() async throws {
        let bundleURL = tempDirectory.appendingPathComponent("AtomicProject.voicefix")
        let metadata = ProjectMetadata(
            name: "AtomicConcurrentProject",
            sourceStorageMode: .cloned(relativePath: "source.mp4"),
            designatedNarrationTrackID: 1,
            totalDuration: CMTime(value: 6000, timescale: 600),
            cues: []
        )

        let bundle = try ProjectBundle.create(at: bundleURL, metadata: metadata)
        let projectJSONURL = bundle.projectJSONURL

        let writeIterations = 80
        let readerTasksCount = 6
        let readsPerTask = 150

        // Use a flag to coordinate start
        let isWritingActive = ManagedAtomicBool(true)
        let corruptReadCount = ManagedAtomicInt(0)
        let successfulReadCount = ManagedAtomicInt(0)

        // Run concurrent readers and writer concurrently
        await withTaskGroup(of: Void.self) { group in
            // Writer task
            group.addTask {
                var currentBundle = bundle
                for i in 0..<writeIterations {
                    let cue = Cue(
                        timeRange: CMTimeRange(
                            start: CMTime(value: Int64(i * 100), timescale: 600),
                            duration: CMTime(value: 100, timescale: 600)
                        ),
                        text: "Generated cue iteration #\(i) with detailed text content to increase payload size."
                    )
                    currentBundle.cues.append(cue)
                    currentBundle.metadata.name = "Updated Project Iteration \(i)"

                    do {
                        try ProjectBundleSerializer.save(bundle: currentBundle)
                    } catch {
                        // Write failed
                    }
                    // Small yield to let readers interleave
                    await Task.yield()
                }
                isWritingActive.set(false)
            }

            // Reader tasks
            for _ in 0..<readerTasksCount {
                group.addTask {
                    let decoder = ProjectBundleSerializer.makeDecoder()
                    for _ in 0..<readsPerTask {
                        do {
                            let data = try Data(contentsOf: projectJSONURL)
                            if data.isEmpty {
                                corruptReadCount.increment()
                                continue
                            }
                            // Must decode completely without JSON syntax error
                            let decoded = try decoder.decode(ProjectMetadata.self, from: data)
                            if !decoded.name.isEmpty {
                                successfulReadCount.increment()
                            }
                        } catch {
                            // Any decoding failure or read failure means partial/torn read!
                            corruptReadCount.increment()
                        }
                        await Task.yield()
                    }
                }
            }
        }

        #expect(corruptReadCount.value == 0, "Atomic save must never allow partial or corrupt reads! Found \(corruptReadCount.value) corrupt reads.")
        #expect(successfulReadCount.value > 0, "At least some successful reads must occur.")
    }

    // MARK: - 3. KeychainVault Edge Cases & Error Handling

    @Test("KeychainVault empty and whitespace key handling")
    func test_keychain_vault_whitespace_handling() {
        let vault = KeychainVault(serviceIdentifier: "com.macdub.adversarial.test.\(UUID().uuidString)")
        defer {
            for service in ServiceKey.allCases {
                try? vault.delete(keyFor: service)
            }
        }

        let invalidInputs = [
            "",
            "   ",
            "\t",
            "\n",
            "\r\n",
            " \t \n \r  \t\t "
        ]

        for input in invalidInputs {
            for service in ServiceKey.allCases {
                #expect(throws: KeychainVaultError.self) {
                    try vault.save(key: input, for: service)
                }
            }
        }
    }

    @Test("KeychainVault delete nonexistent key is idempotent")
    func test_keychain_vault_delete_nonexistent_is_idempotent() {
        let vault = KeychainVault(serviceIdentifier: "com.macdub.adversarial.test.\(UUID().uuidString)")

        // For all services, delete when nothing has ever been saved
        for service in ServiceKey.allCases {
            #expect(throws: Never.self) {
                try vault.delete(keyFor: service)
            }
            #expect(!vault.has(keyFor: service))
            #expect((try? vault.get(keyFor: service)) == nil)
        }
    }

    @Test("KeychainVault very large credential (64 KB)")
    func test_keychain_vault_large_credential() throws {
        let vault = KeychainVault(serviceIdentifier: "com.macdub.adversarial.test.\(UUID().uuidString)")
        defer {
            try? vault.delete(keyFor: .elevenLabs)
        }

        let largeSecret = String(repeating: "A1b2C3d4E5f6G7h8", count: 4096) // 64 KB
        try vault.save(key: largeSecret, for: .elevenLabs)

        #expect(vault.has(keyFor: .elevenLabs))
        let retrieved = try vault.get(keyFor: .elevenLabs)
        #expect(retrieved == largeSecret)
    }

    @Test("KeychainVault concurrent access thread safety")
    func test_keychain_vault_concurrent_access() async throws {
        let vault = KeychainVault(serviceIdentifier: "com.macdub.adversarial.test.\(UUID().uuidString)")
        defer {
            for service in ServiceKey.allCases {
                try? vault.delete(keyFor: service)
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let service: ServiceKey = (i % 3 == 0) ? .elevenLabs : (i % 3 == 1) ? .resemble : .gemini
                    let key = "concurrent_key_\(i)_\(UUID().uuidString)"
                    try? vault.save(key: key, for: service)
                    _ = try? vault.get(keyFor: service)
                    _ = vault.has(keyFor: service)
                }
            }
        }
    }

    // MARK: - 4. Additional Robustness & Boundary Challenges

    @Test("ProjectBundleSerializer load fails gracefully on missing or corrupt project.json")
    func test_project_bundle_load_corrupt_json() throws {
        let fakeBundleURL = tempDirectory.appendingPathComponent("Corrupt.voicefix")
        try FileManager.default.createDirectory(at: fakeBundleURL, withIntermediateDirectories: true)

        // Missing project.json
        #expect(throws: ProjectBundleSerializerError.self) {
            try ProjectBundleSerializer.load(from: fakeBundleURL)
        }

        // Corrupted JSON content
        let projectJSON = fakeBundleURL.appendingPathComponent("project.json")
        try "{ this is not valid JSON at all }".write(to: projectJSON, atomically: true, encoding: .utf8)

        #expect(throws: DecodingError.self) {
            try ProjectBundleSerializer.load(from: fakeBundleURL)
        }
    }

    @Test("Cue boundary sorting and invariant validity")
    func test_cue_boundary_invariants() {
        let t0 = CMTime(value: 0, timescale: 600)
        let t1 = CMTime(value: 300, timescale: 600)
        let t2 = CMTime(value: 600, timescale: 600)

        let cue1 = Cue(timeRange: CMTimeRange(start: t0, duration: t1), text: "First")
        let cue2 = Cue(timeRange: CMTimeRange(start: t1, duration: t1), text: "Second")

        #expect(CMTimeCompare(cue1.end, cue2.start) == 0)
        #expect(CMTimeCompare(cue1.start, t0) == 0)
        #expect(CMTimeCompare(cue2.end, t2) == 0)
    }

    @Test("CMTime special values Codable roundtrip")
    func test_cmtime_special_values_codable() throws {
        let specialTimes: [CMTime] = [
            .zero,
            .invalid,
            .positiveInfinity,
            .negativeInfinity,
            .indefinite,
            CMTime(value: -500, timescale: 600) // negative time
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for original in specialTimes {
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(CMTime.self, from: data)

            #expect(decoded.value == original.value)
            #expect(decoded.timescale == original.timescale)
            #expect(decoded.flags == original.flags)
            #expect(decoded.epoch == original.epoch)
            #expect(decoded.isValid == original.isValid)
            #expect(decoded.isPositiveInfinity == original.isPositiveInfinity)
        }
    }

    @Test("BookmarkManager rejects corrupted bookmark data")
    func test_bookmark_corrupted_data_rejection() {
        let corruptData = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33])

        #expect {
            try BookmarkManager.resolveBookmark(data: corruptData)
        } throws: { error in
            guard case BookmarkError.resolutionFailed = error else { return false }
            return true
        }
    }

    @Test("CredentialLeakScanner adversarial edge cases")
    func test_credential_leak_scanner_adversarial_cases() throws {
        let scanner = CredentialLeakScanner.shared

        // 1. Secret shorter than 8 chars should NOT trigger false positive knownSecretMatch
        let shortSecret = "abc1234" // 7 chars
        let jsonWithShort = """
        { "name": "Project", "id": "\(UUID().uuidString)", "description": "Contains \(shortSecret) somewhere" }
        """.data(using: .utf8)!
        let violations1 = try scanner.scan(projectJSONData: jsonWithShort, knownSecrets: [shortSecret])
        let hasShortMatch = violations1.contains { $0.rule == .knownSecretMatch }
        #expect(!hasShortMatch, "Secrets shorter than 8 characters should not trigger knownSecretMatch")

        // 2. Secret exactly 8 chars should be detected
        let eightCharSecret = "sk-exact"
        let jsonWithEight = """
        { "name": "Project", "id": "\(UUID().uuidString)", "comment": "Token: \(eightCharSecret)" }
        """.data(using: .utf8)!
        let violations2 = try scanner.scan(projectJSONData: jsonWithEight, knownSecrets: [eightCharSecret])
        let hasEightMatch = violations2.contains { $0.rule == .knownSecretMatch }
        #expect(hasEightMatch, "8-character secret must be detected by scanner")

        // 3. No catastrophic backtracking or hang with large clean JSON (500 KB)
        let largeCleanString = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 10000)
        let largeCleanJSON = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Large Clean",
            "text": "\(largeCleanString)"
        }
        """.data(using: .utf8)!
        let start = Date()
        let violations3 = try scanner.scan(projectJSONData: largeCleanJSON, knownSecrets: [])
        let elapsed = Date().timeIntervalSince(start)
        #expect(violations3.isEmpty)
        #expect(elapsed < 2.0, "Scanner must process large payload quickly without catastrophic regex backtracking (took \(elapsed)s)")
    }

    // MARK: - 5. Comprehensive Challenger Stress Tests

    @Test("APFS clone failure handling on read-only destination")
    func test_apfs_clone_readonly_destination_failure() throws {
        let sourceURL = tempDirectory.appendingPathComponent("source_for_ro_test.mp4")
        try "test data".data(using: .utf8)!.write(to: sourceURL)

        let readOnlyDestDir = tempDirectory.appendingPathComponent("readonly_dest_dir", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnlyDestDir, withIntermediateDirectories: true)
        // Make directory read-only (0o555: r-xr-xr-x)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlyDestDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyDestDir.path)
        }

        let destFileURL = readOnlyDestDir.appendingPathComponent("destination_file.mp4")
        #expect {
            try APFSCloner.clone(from: sourceURL, to: destFileURL)
        } throws: { error in
            guard case APFSCloningError.cloningFailed = error else { return false }
            return true
        }
    }

    @Test("APFS clone failure handling on nonexistent source")
    func test_apfs_clone_nonexistent_source_failure() {
        let fakeSource = tempDirectory.appendingPathComponent("nonexistent_source_\(UUID().uuidString).mov")
        let dest = tempDirectory.appendingPathComponent("dest.mov")

        #expect {
            try APFSCloner.clone(from: fakeSource, to: dest)
        } throws: { error in
            guard case APFSCloningError.cloningFailed = error else { return false }
            return true
        }
    }

    @Test("Security-scoped bookmark access lifecycle and error propagation")
    func test_bookmark_scoped_access_lifecycle() throws {
        let testFile = tempDirectory.appendingPathComponent("bookmark_lifecycle.mov")
        try "Media Content".data(using: .utf8)!.write(to: testFile)

        // Verify normal execution
        let result = try BookmarkManager.withSecurityScopedAccess(to: testFile) { url in
            FileManager.default.fileExists(atPath: url.path)
        }
        #expect(result == true)

        // Verify error propagation and clean teardown
        enum DummyError: Error { case testFailure }
        #expect(throws: DummyError.self) {
            try BookmarkManager.withSecurityScopedAccess(to: testFile) { _ in
                throw DummyError.testFailure
            }
        }
    }

    @Test("KeychainVault special characters and emojis handling")
    func test_keychain_vault_special_characters_and_emojis() throws {
        let vault = KeychainVault(serviceIdentifier: "com.macdub.adversarial.special.\(UUID().uuidString)")
        defer {
            for service in ServiceKey.allCases {
                try? vault.delete(keyFor: service)
            }
        }

        let complexSecret = "sk-🔑-t0k3n_✨!@#$%^&*()_+=~`{}[]|;:'\"<>,.?/\\_日本語_العربية"
        try vault.save(key: complexSecret, for: .resemble)
        #expect(vault.has(keyFor: .resemble))
        let retrieved = try vault.get(keyFor: .resemble)
        #expect(retrieved == complexSecret)

        // Update with another complex secret
        let updatedSecret = "updated-🚀-pass_12345!@#\nwith_trailing_internal_newlines"
        try vault.save(key: updatedSecret, for: .resemble)
        let updatedRetrieved = try vault.get(keyFor: .resemble)
        #expect(updatedRetrieved == updatedSecret)
    }

    @Test("KeychainVault multiple redundant deletions are idempotent")
    func test_keychain_vault_multiple_redundant_deletions() throws {
        let vault = KeychainVault(serviceIdentifier: "com.macdub.adversarial.redundant.\(UUID().uuidString)")
        // Perform 5 consecutive deletions of nonexistent key
        for _ in 0..<5 {
            #expect(throws: Never.self) {
                try vault.delete(keyFor: .gemini)
            }
        }
        #expect(!vault.has(keyFor: .gemini))
    }

    @Test("CredentialLeakScanner bundle file user path detection")
    func test_credential_leak_scanner_bundle_user_path() throws {
        let bundleURL = tempDirectory.appendingPathComponent("UserPathLog.voicefix")
        let metadata = ProjectMetadata(
            name: "UserPathLogProject",
            sourceStorageMode: .cloned(relativePath: "source.mp4"),
            designatedNarrationTrackID: 1,
            totalDuration: CMTime(value: 3000, timescale: 600)
        )
        let bundle = try ProjectBundle.create(at: bundleURL, metadata: metadata)

        // Write a debug.log containing an absolute user path
        let logURL = bundle.rootURL.appendingPathComponent("debug.log")
        let logContent = "Processed source from /Users/johndoe/Desktop/screen_recording.mov successfully."
        try logContent.write(to: logURL, atomically: true, encoding: .utf8)

        let scanner = CredentialLeakScanner.shared
        let violations = try scanner.scan(bundleURL: bundle.rootURL, knownSecrets: [])
        let hasUserPath = violations.contains { $0.rule == .absoluteUserPath }
        #expect(hasUserPath, "CredentialLeakScanner must detect user absolute path in bundle text and log files")
    }

    @Test("CredentialLeakScanner detects credentials in .env files in bundle")
    func test_credential_leak_scanner_env_file_detection() throws {
        let bundleURL = tempDirectory.appendingPathComponent("EnvBundle.voicefix")
        let metadata = ProjectMetadata(
            name: "EnvBundleProject",
            sourceStorageMode: .cloned(relativePath: "source.mp4"),
            designatedNarrationTrackID: 1,
            totalDuration: CMTime(value: 3000, timescale: 600)
        )
        let bundle = try ProjectBundle.create(at: bundleURL, metadata: metadata)

        // Write a .env file with API key
        let envURL = bundle.rootURL.appendingPathComponent(".env")
        let envContent = "ELEVENLABS_API_KEY=sk_1234567890abcdef1234567890abcdef\n"
        try envContent.write(to: envURL, atomically: true, encoding: .utf8)

        let scanner = CredentialLeakScanner.shared
        let violations = try scanner.scan(bundleURL: bundle.rootURL, knownSecrets: [])
        let hasKeyViolation = violations.contains { $0.rule == .providerPatternMatch }
        #expect(hasKeyViolation, "CredentialLeakScanner must scan .env files in bundle for leaked API credentials")
    }

    @Test("CredentialLeakScanner absolute user path distinction")
    func test_credential_leak_scanner_user_path_distinction() throws {
        let scanner = CredentialLeakScanner.shared

        // User paths that MUST trigger
        let userPaths = [
            "/Users/alice/Library/Caches/sample.mp4",
            "/Users/john.doe-dev/Desktop/file.wav",
            "/home/runner/workspace/audio.m4a"
        ]
        for path in userPaths {
            let json = "{ \"path\": \"\(path)\" }".data(using: .utf8)!
            let violations = try scanner.scan(projectJSONData: json)
            let hasPathViolation = violations.contains { $0.rule == .absoluteUserPath }
            #expect(hasPathViolation, "Path '\(path)' must be flagged as user absolute path")
        }

        // System / temporary paths that must NOT trigger
        let systemPaths = [
            "/tmp/temp_audio.wav",
            "/private/var/folders/xx/123/file.mp4",
            "/System/Library/Frameworks",
            "/Applications/macdub.app"
        ]
        for path in systemPaths {
            let json = "{ \"path\": \"\(path)\" }".data(using: .utf8)!
            let violations = try scanner.scan(projectJSONData: json)
            let hasPathViolation = violations.contains { $0.rule == .absoluteUserPath }
            #expect(!hasPathViolation, "System path '\(path)' should not be flagged as user home path")
        }
    }
}

// MARK: - Helper Atomic Types for Concurrency Testing

private final class ManagedAtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool

    init(_ value: Bool) {
        self._value = value
    }

    func set(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        _value = value
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
}

private final class ManagedAtomicInt: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int

    init(_ value: Int) {
        self._value = value
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        _value += 1
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
}
