import Testing
import AVFoundation
import CoreMedia
import Foundation
@testable import MacDubCore
import FluidAudio

@Suite("Gate F: Local PocketTTS Voice Cloning & Synthesis Acceptance Tests")
struct PocketTTSAcceptanceTests {

    private func isLocalAIRunner() -> Bool {
        ProcessInfo.processInfo.environment["MACDUB_RUN_LOCAL_AI_TESTS"] == "1"
    }

    @Test("Real PocketTTS Core ML model download, voice cloning, and audio synthesis (Opt-in)")
    func test_real_pocket_tts_cloning_and_synthesis() async throws {
        guard isLocalAIRunner() else {
            print("[NOTICE] PocketTTS local acceptance test skipped. Run with MACDUB_RUN_LOCAL_AI_TESTS=1 on Apple Silicon Mac to verify.")
            return
        }

        let manager = PocketTtsManager()
        try await manager.initialize()
        #expect(await manager.isAvailable)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a short reference voice audio WAV (44.1kHz mono)
        let refURL = tempDir.appendingPathComponent("reference_speaker.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000.0, channels: 1)!
        let frameCount = AVAudioFrameCount(24000 * 3) // 3.0 seconds
        let refBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        refBuffer.frameLength = frameCount
        let channel = refBuffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            channel[i] = Float(sin(2.0 * .pi * 220.0 * Double(i) / 24000.0)) * 0.4
        }
        let refFile = try AVAudioFile(forWriting: refURL, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try refFile.write(from: refBuffer)

        // Clone speaker from reference voice
        let voiceData = try await manager.cloneVoice(from: refURL)

        // Synthesize short test sentence
        let testText = "MacDub voice cloning verified on Apple Silicon Neural Engine."
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
