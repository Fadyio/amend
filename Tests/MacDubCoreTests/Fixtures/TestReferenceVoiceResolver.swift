import Foundation

public enum TestReferenceVoiceResolver {
    /// Resolves the authentic human speech reference audio URL deterministically.
    ///
    /// Resolution order:
    /// 1. `MACDUB_TEST_REFERENCE_VOICE` environment variable if supplied, non-empty, and the target file exists.
    /// 2. Known repository test fixture path derived from the test source file root.
    /// 3. Current working directory fallback for SwiftPM.
    /// 4. Returns nil (caller should fail explicitly).
    public static func resolveReferenceVoiceURL(filePath: String = #filePath) -> URL? {
        // 1. Environment variable override
        if let envPath = ProcessInfo.processInfo.environment["MACDUB_TEST_REFERENCE_VOICE"],
           !envPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           FileManager.default.fileExists(atPath: envPath) {
            return URL(fileURLWithPath: envPath)
        }

        // 2. Known repository test fixture path derived from this file or calling test file
        // TestReferenceVoiceResolver.swift is at Tests/MacDubCoreTests/Fixtures/TestReferenceVoiceResolver.swift
        let thisFile = URL(fileURLWithPath: #filePath)
        let fixturesDir = thisFile.deletingLastPathComponent() // Tests/MacDubCoreTests/Fixtures
        let candidateFixture = fixturesDir.appendingPathComponent("human_speech_reference.wav")
        if FileManager.default.fileExists(atPath: candidateFixture.path) {
            return candidateFixture
        }

        // Check relative to the caller's #filePath if different
        let callerFile = URL(fileURLWithPath: filePath)
        let macDubCoreTestsDir = callerFile.deletingLastPathComponent().deletingLastPathComponent() // if in Suites/
        let suiteCandidate = macDubCoreTestsDir.appendingPathComponent("Fixtures/human_speech_reference.wav")
        if FileManager.default.fileExists(atPath: suiteCandidate.path) {
            return suiteCandidate
        }

        // 3. Current working directory fallback for SwiftPM test runners
        let cwdCandidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/MacDubCoreTests/Fixtures/human_speech_reference.wav")
        if FileManager.default.fileExists(atPath: cwdCandidate.path) {
            return cwdCandidate
        }

        // 4. Return nil indicating resolution failure
        return nil
    }
}
