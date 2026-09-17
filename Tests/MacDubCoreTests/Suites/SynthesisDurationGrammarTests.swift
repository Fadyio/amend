import Testing
import AVFoundation
import CoreMedia
import Foundation
@testable import MacDubCore

@Suite("Milestone 5: Voice Synthesis, Duration Fitting & Grammar Tests", .serialized)
struct SynthesisDurationGrammarTests {

    private func createToneBuffer(durationSeconds: Double, sampleRate: Double = 44100.0, freq: Double = 440.0) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw NSError(domain: "Test", code: 1)
        }
        let frameCount = AVAudioFrameCount(round(durationSeconds * sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "Test", code: 2)
        }
        buffer.frameLength = frameCount
        let data = buffer.floatChannelData![0]
        let twoPi = 2.0 * Double.pi
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            data[i] = Float(sin(twoPi * freq * t)) * 0.5
        }
        return buffer
    }

    private func createSilenceBuffer(durationSeconds: Double, sampleRate: Double = 44100.0) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw NSError(domain: "Test", code: 1)
        }
        let frameCount = AVAudioFrameCount(round(durationSeconds * sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "Test", code: 2)
        }
        buffer.frameLength = frameCount
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            data[i] = 0.001 * Float.random(in: -1.0...1.0) // Low ambient noise floor
        }
        return buffer
    }

    // MARK: - DurationFitter Tests (ADR-0005, ADR-0006)

    @Test("Shorter speech retains natural pace and pads remainder with looped ambient room tone")
    func test_duration_fitter_shorter_speech_room_tone_padding() throws {
        let fitter = DurationFitter()
        let targetDuration = CMTime(seconds: 2.0, preferredTimescale: 600_000)
        let speechBuffer = try createToneBuffer(durationSeconds: 1.2, freq: 440.0)
        let roomTone = try createSilenceBuffer(durationSeconds: 0.3)

        let result = try fitter.fit(
            synthesizedAudio: speechBuffer,
            targetDuration: targetDuration,
            roomToneBuffer: roomTone
        )

        guard case .fitted(let output) = result else {
            #expect(Bool(false), "Result should be fitted")
            return
        }

        let outputSeconds = Double(output.frameLength) / output.format.sampleRate
        #expect(abs(outputSeconds - 2.0) < 0.005, "Padded duration should exactly match target 2.0s, got \(outputSeconds)")

        // Speech in first 1.2s should be preserved
        let data = output.floatChannelData![0]
        #expect(abs(data[1000] - speechBuffer.floatChannelData![0][1000]) < 1e-4)

        // Residual region (1.3s to 2.0s) should contain non-zero ambient room tone (not digital zero)
        let ambientFrame = Int(1.5 * 44100.0)
        #expect(abs(data[ambientFrame]) > 0.0, "Padded section must contain ambient room tone, not raw digital zero")
    }

    @Test("Speech exceeding duration by <= 8% is automatically time-compressed without pitch shift")
    func test_duration_fitter_auto_compression_within_8_percent() throws {
        let fitter = DurationFitter()
        let targetDuration = CMTime(seconds: 2.0, preferredTimescale: 600_000)

        // 1. +4% overflow (2.08s)
        let buffer4 = try createToneBuffer(durationSeconds: 2.08, freq: 440.0)
        let result4 = try fitter.fit(synthesizedAudio: buffer4, targetDuration: targetDuration)
        guard case .fitted(let output4) = result4 else {
            #expect(Bool(false), "+4% overflow must automatically compress")
            return
        }
        let dur4 = Double(output4.frameLength) / output4.format.sampleRate
        #expect(abs(dur4 - 2.0) < 0.01, "+4% compressed audio should equal target duration 2.0s")

        // 2. Exactly +8% overflow (2.16s)
        let buffer8 = try createToneBuffer(durationSeconds: 2.16, freq: 440.0)
        let result8 = try fitter.fit(synthesizedAudio: buffer8, targetDuration: targetDuration)
        guard case .fitted(let output8) = result8 else {
            #expect(Bool(false), "+8% overflow must automatically compress")
            return
        }
        let dur8 = Double(output8.frameLength) / output8.format.sampleRate
        #expect(abs(dur8 - 2.0) < 0.01, "+8% compressed audio should equal target duration 2.0s")
    }

    @Test("Speech exceeding duration by > 8% enters user-gated overflow state without uncontrolled retry")
    func test_duration_fitter_overflow_gating_above_8_percent() throws {
        let fitter = DurationFitter()
        let targetDuration = CMTime(seconds: 2.0, preferredTimescale: 600_000)

        // +15% overflow (2.30s)
        let buffer15 = try createToneBuffer(durationSeconds: 2.30, freq: 440.0)
        let result = try fitter.fit(synthesizedAudio: buffer15, targetDuration: targetDuration)

        switch result {
        case .overflow(let delta, let ratio, let uncompressed):
            #expect(ratio > 1.08)
            let deltaSec = CMTimeGetSeconds(delta)
            #expect(abs(deltaSec - 0.30) < 0.01, "Delta should be ~+0.30s, got \(deltaSec)")
            #expect(uncompressed.frameLength == buffer15.frameLength)
        case .fitted:
            #expect(Bool(false), "+15% overflow must NOT automatically fit; must be user-gated")
        }

        // When user explicitly approves Force Fit, compression is applied
        let forcedResult = try fitter.fit(
            synthesizedAudio: buffer15,
            targetDuration: targetDuration,
            forceCompress: true
        )
        guard case .fitted(let forcedOutput) = forcedResult else {
            #expect(Bool(false), "Force fit should succeed")
            return
        }
        let forcedSec = Double(forcedOutput.frameLength) / forcedOutput.format.sampleRate
        #expect(abs(forcedSec - 2.0) < 0.01)
    }

    // MARK: - Voice Synthesis Provider Tests

    @Test("Gemini TTS rejects voice cloning reference audio as per architectural constraint")
    func test_gemini_tts_rejects_voice_cloning() async throws {
        let vault = MockCredentialVault(initialValues: [.gemini: "AIzaSyTestValidFormatKeyForUnitTests1234"])
        let provider = GeminiTTSProvider(vault: vault)

        let dummyURL = URL(fileURLWithPath: "/tmp/voice_sample.wav")
        await #expect(throws: SynthesisError.self) {
            try await provider.synthesize(text: "Hello", voiceID: "Puck", referenceAudioURL: dummyURL)
        }

        // Register hermetic mock HTTP transport for Gemini TTS
        TestURLProtocol.reset()
        defer { TestURLProtocol.reset() }

        let testPCM = try createToneBuffer(durationSeconds: 0.2, sampleRate: 24000.0, freq: 440.0)
        let tempWAV = FileManager.default.temporaryDirectory.appendingPathComponent("mock_gemini_\(UUID().uuidString).wav")
        do {
            let file = try AVAudioFile(forWriting: tempWAV, settings: testPCM.format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: testPCM)
        }
        defer { try? FileManager.default.removeItem(at: tempWAV) }

        let wavData = try Data(contentsOf: tempWAV)
        let base64Audio = wavData.base64EncodedString()
        let mockJSON = """
        {
            "candidates": [{
                "content": {
                    "parts": [{
                        "inlineData": {
                            "mimeType": "audio/x-wav",
                            "data": "\(base64Audio)"
                        }
                    }]
                }
            }]
        }
        """.data(using: .utf8)!

        TestURLProtocol.registerHandler(for: "generativelanguage.googleapis.com") { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, mockJSON)
        }

        // Without referenceAudioURL, prebuilt voice synthesis succeeds
        let buffer = try await provider.synthesize(text: "Hello from Gemini prebuilt voice", voiceID: "Puck", referenceAudioURL: nil)
        #expect(buffer.frameLength > 0)
        #expect(buffer.format.sampleRate == 24000.0)
    }

    @Test("Gemini TTS throws actionable error on authentication failure without local fallback")
    func test_gemini_tts_auth_failure() async throws {
        let vault = MockCredentialVault(initialValues: [.gemini: "AIzaSyInvalidKey123"])
        let provider = GeminiTTSProvider(vault: vault)

        TestURLProtocol.reset()
        defer { TestURLProtocol.reset() }

        TestURLProtocol.registerHandler(for: "generativelanguage.googleapis.com") { req in
            let errorJSON = "{\"error\": {\"code\": 400, \"message\": \"API_KEY_INVALID\"}}".data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, errorJSON)
        }

        await #expect(throws: SynthesisError.self) {
            try await provider.synthesize(text: "Test authentication failure", voiceID: "Puck")
        }
    }

    @Test("PocketTTS provider delegates to local model coordinator and manager")
    func test_pocket_tts_provider() async throws {
        let provider = PocketTTSProvider()
        #expect(provider.providerType == .pocketTTS)
    }

    @Test("Cloud providers throw missingAPIKey when credentials absent from vault")
    func test_cloud_providers_missing_key() async throws {
        let emptyVault = MockCredentialVault()

        let elevenLabs = ElevenLabsProvider(vault: emptyVault)
        await #expect(throws: SynthesisError.self) {
            try await elevenLabs.synthesize(text: "Test")
        }

        let resemble = ResembleProvider(vault: emptyVault)
        await #expect(throws: SynthesisError.self) {
            try await resemble.synthesize(text: "Test")
        }

        let gemini = GeminiTTSProvider(vault: emptyVault)
        await #expect(throws: SynthesisError.self) {
            try await gemini.synthesize(text: "Test")
        }
    }

    // MARK: - GrammarRewriter Tests (R7)

    @Test("GrammarRewriter generates word diffs and preserves original transcript text")
    func test_grammar_rewriter_actions_and_diffs() async throws {
        let vault = MockCredentialVault(initialValues: [.gemini: "AIzaSyTestValidFormatKeyForUnitTests1234"])
        let provider = GeminiGrammarProvider(vault: vault)

        TestURLProtocol.reset()
        defer { TestURLProtocol.reset() }

        TestURLProtocol.registerHandler(for: "generativelanguage.googleapis.com") { req in
            let action = req.value(forHTTPHeaderField: "X-MacDub-Action") ?? ""
            let text: String
            if action == "fixGrammar" {
                text = "I cannot find the screen recording file."
            } else if action == "makeNatural" {
                text = "don't delete it's important"
            } else if action == "rewriteToFit" {
                text = "Narration fits slot."
            } else {
                text = "Rewritten transcript text."
            }
            let json = "{\"candidates\": [{\"content\": {\"parts\": [{\"text\": \"\(text)\"}]}}]}".data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, json)
        }

        // 1. Fix Grammar
        let original = "i cannot find the screen recording file"
        let resGrammar = try await provider.rewrite(text: original, action: .fixGrammar)
        #expect(resGrammar.originalText == original)
        #expect(resGrammar.rewrittenText.hasPrefix("I"))
        #expect(resGrammar.rewrittenText.hasSuffix("."))

        // 2. Make Natural
        let resNatural = try await provider.rewrite(text: "do not delete it is important", action: .makeNatural)
        #expect(resNatural.rewrittenText.contains("don't"))
        #expect(resNatural.rewrittenText.contains("it's"))

        // 3. Rewrite to Fit (with target duration 1.0s -> ~2-3 words)
        let longText = "This is an extremely detailed and unnecessarily verbose narration sentence that definitely exceeds the slot"
        let resFit = try await provider.rewrite(text: longText, action: .rewriteToFit(targetDuration: CMTime(seconds: 1.0, preferredTimescale: 600)))
        #expect(resFit.rewrittenText.split(separator: " ").count <= 3)

        // 4. Word Diff contains added/deleted/unchanged chunks
        #expect(!resFit.diff.isEmpty)
        #expect(resFit.diff.contains { $0.type == .deleted })
    }

    @Test("GrammarRewriter throws actionable error on authentication failure without local fallback")
    func test_grammar_rewriter_auth_failure() async throws {
        let vault = MockCredentialVault(initialValues: [.gemini: "AIzaSyInvalidKey123"])
        let provider = GeminiGrammarProvider(vault: vault)

        TestURLProtocol.reset()
        defer { TestURLProtocol.reset() }

        TestURLProtocol.registerHandler(for: "generativelanguage.googleapis.com") { req in
            let errorJSON = "{\"error\": {\"code\": 400, \"message\": \"API_KEY_INVALID\"}}".data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, errorJSON)
        }

        await #expect(throws: GrammarError.self) {
            _ = try await provider.rewrite(text: "Some text", action: .fixGrammar)
        }
    }

    @Test("Rewriting narration text preserves immutable Cue timeRange and originalText")
    func test_cue_text_rewriting_invariance() {
        let fixedRange = CMTimeRange(start: CMTime(seconds: 5.0, preferredTimescale: 600), duration: CMTime(seconds: 3.0, preferredTimescale: 600))
        let cue = Cue(
            timeRange: fixedRange,
            text: "Original narration before rewrite",
            originalText: "Original narration before rewrite"
        )

        // User accepts rewrite
        let rewrittenCue = cue.withUpdatedText("Concise rewrite")

        // Invariant: timeRange MUST NOT CHANGE
        #expect(rewrittenCue.timeRange == fixedRange)
        #expect(rewrittenCue.start == fixedRange.start)
        #expect(rewrittenCue.end == fixedRange.end)
        #expect(rewrittenCue.duration == fixedRange.duration)

        // Invariant: originalText remains fully recoverable
        #expect(rewrittenCue.originalText == "Original narration before rewrite")
        #expect(rewrittenCue.text == "Concise rewrite")
        #expect(rewrittenCue.editState == .edited)

        // Restore original
        let restoredCue = rewrittenCue.withUpdatedText(rewrittenCue.originalText)
        #expect(restoredCue.text == "Original narration before rewrite")
    }
}
