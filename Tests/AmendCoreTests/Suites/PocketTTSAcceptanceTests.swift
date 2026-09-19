import Testing
import AVFoundation
import CoreMedia
import Foundation
@testable import AmendCore
import FluidAudio

@Suite("Gate F: Local PocketTTS Voice Cloning & Synthesis Acceptance Tests")
struct PocketTTSAcceptanceTests {

    @Test(
        "Real PocketTTS Core ML model download, voice cloning, and audio synthesis (Opt-in)",
        .enabled(if: ProcessInfo.processInfo.environment["AMEND_RUN_LOCAL_AI_TESTS"] == "1")
    )
    func test_real_pocket_tts_cloning_and_synthesis() async throws {
        guard let refURL = TestReferenceVoiceResolver.resolveReferenceVoiceURL(filePath: #filePath) else {
            Issue.record("Authentic human speech fixture human_speech_reference.wav could not be resolved from repository or AMEND_TEST_REFERENCE_VOICE")
            return
        }

        let manager = PocketTtsManager()
        try await manager.initialize()
        #expect(await manager.isAvailable)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Clone speaker from authentic human speech reference voice
        let voiceData = try await manager.cloneVoice(from: refURL)

        // Synthesize short test sentence
        let testText = "Amend voice cloning verified on Apple Silicon Neural Engine."
        let synthesizedData = try await manager.synthesize(text: testText, voiceData: voiceData)
        #expect(!synthesizedData.isEmpty)

        // Save output to disk and verify audio properties
        let outputWAV = tempDir.appendingPathComponent("cloned_output.wav")
        try synthesizedData.write(to: outputWAV)
        #expect(FileManager.default.fileExists(atPath: outputWAV.path))

        let audioFile = try AVAudioFile(forReading: outputWAV)
        #expect(audioFile.length > 0)
        #expect(audioFile.processingFormat.sampleRate == 24000.0)

        let durationSeconds = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        #expect(durationSeconds > 0.5, "Synthesized output duration should be > 0.5s, got \(durationSeconds)s")
    }
}
