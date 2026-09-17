import Testing
import AVFoundation
import CoreMedia
import Foundation
@testable import MacDubCore
@testable import MacDubApp
import FluidAudio

@Suite("Blocker Verification: Provider Contracts, Overflow Gating, Reference Voice & MOV Export", .serialized)
struct ProviderAndOverflowBlockerTests {

    private func createTempDir() throws -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return temp
    }

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

    private func countZeroCrossings(in buffer: AVAudioPCMBuffer, startSec: Double, durationSec: Double) -> Int {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let sr = buffer.format.sampleRate
        let startFrame = Int(startSec * sr)
        let endFrame = min(Int(buffer.frameLength), Int((startSec + durationSec) * sr))
        guard endFrame > startFrame + 1 else { return 0 }
        var crossings = 0
        for i in (startFrame + 1)..<endFrame {
            let prev = channel[i - 1]
            let curr = channel[i]
            if (prev < 0 && curr >= 0) || (prev > 0 && curr <= 0) {
                crossings += 1
            }
        }
        return crossings
    }

    private func writeBufferToWAV(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        let parentDir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    // MARK: - BLOCKER 2: Gemini Grammar Contract (gemini-2.5-flash & x-goog-api-key)

    @Test("Gemini Grammar uses current model and header-based authentication without API key in URL")
    func test_gemini_grammar_contract() async throws {
        let vault = MockCredentialVault(initialValues: [.gemini: "AIzaSyTestValidFormatKey1234"])
        let provider = GeminiGrammarProvider(vault: vault)

        TestURLProtocol.reset()
        defer { TestURLProtocol.reset() }

        var capturedRequest: URLRequest? = nil
        TestURLProtocol.registerHandler(for: "generativelanguage.googleapis.com") { req in
            capturedRequest = req
            let mockJSON = """
            {
                "candidates": [{
                    "content": {
                        "parts": [{ "text": "Corrected transcript text." }]
                    }
                }]
            }
            """.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, mockJSON)
        }

        let result = try await provider.rewrite(text: "uncorrected transcript text", action: .fixGrammar)
        #expect(result.rewrittenText == "Corrected transcript text.")

        guard let req = capturedRequest, let url = req.url else {
            #expect(Bool(false), "Captured request must exist")
            return
        }

        // Must NOT put API key in URL query
        #expect(url.query == nil || !url.query!.contains("key="), "API key must NOT appear in URL query")
        #expect(url.path.contains("gemini-2.5-flash"), "Must use current Gemini model: \(url.path)")

        // Must send x-goog-api-key header
        let authHeader = req.value(forHTTPHeaderField: "x-goog-api-key")
        #expect(authHeader == "AIzaSyTestValidFormatKey1234", "Must send x-goog-api-key header")
    }

    // MARK: - BLOCKER 3: Gemini TTS Contract (v1beta/interactions & response_format audio)

    @Test("Gemini TTS uses official interactions endpoint, header-based authentication, and documented REST response")
    func test_gemini_tts_contract() async throws {
        let vault = MockCredentialVault(initialValues: [.gemini: "AIzaSyTestValidFormatKey1234"])
        let provider = GeminiTTSProvider(vault: vault)

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

        var capturedRequest: URLRequest? = nil
        TestURLProtocol.registerHandler(for: "generativelanguage.googleapis.com") { req in
            capturedRequest = req
            let mockJSON = """
            {
                "id": "interaction_test_12345",
                "status": "completed",
                "steps": [
                    {
                        "type": "model_output",
                        "content": [
                            {
                                "type": "audio",
                                "data": "\(base64Audio)",
                                "mime_type": "audio/wav"
                            }
                        ]
                    }
                ]
            }
            """.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, mockJSON)
        }

        let buffer = try await provider.synthesize(text: "Synthesize test speech", voiceID: "Puck")
        #expect(buffer.frameLength > 0)

        guard let req = capturedRequest, let url = req.url else {
            #expect(Bool(false), "Captured request must exist")
            return
        }

        #expect(url.query == nil || !url.query!.contains("key="), "API key must NOT appear in URL query")
        #expect(url.path.contains("/v1beta/interactions"), "Must use official /v1beta/interactions endpoint: \(url.path)")
        #expect(req.value(forHTTPHeaderField: "x-goog-api-key") == "AIzaSyTestValidFormatKey1234")

        // Inspect request body contains official schema
        if let bodyData = req.httpBody,
           let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            #expect(json["model"] as? String == GeminiModelConstants.defaultTTSModel)
            #expect(json["input"] as? String == "Synthesize test speech")
            let respFormat = json["response_format"] as? [String: Any]
            #expect(respFormat?["type"] as? String == "audio")
            let genConfig = json["generation_config"] as? [String: Any]
            let speechConfig = genConfig?["speech_config"] as? [[String: Any]]
            #expect(speechConfig?.first?["voice"] as? String == "Puck")
        } else {
            #expect(Bool(false), "Request body must match official interactions JSON schema")
        }
    }

    @Test("Gemini TTS decodes raw L16 audio using explicit returned sample_rate and channels metadata")
    func test_gemini_tts_raw_l16_with_explicit_sample_rate_and_channels() async throws {
        let vault = MockCredentialVault(initialValues: [.gemini: "AIzaSyTestValidFormatKey1234"])
        let provider = GeminiTTSProvider(vault: vault)

        TestURLProtocol.reset()
        defer { TestURLProtocol.reset() }

        // Generate 16kHz mono raw Int16 PCM samples
        let sampleRate = 16000
        let frameCount = 1600 // 0.1s
        var pcmBytes = Data()
        for i in 0..<frameCount {
            let sample = Int16(sin(Double(i) * 2.0 * .pi * 440.0 / Double(sampleRate)) * 10000.0)
            var leSample = sample.littleEndian
            pcmBytes.append(Data(bytes: &leSample, count: 2))
        }
        let base64PCM = pcmBytes.base64EncodedString()

        TestURLProtocol.registerHandler(for: "generativelanguage.googleapis.com") { req in
            let mockJSON = """
            {
                "id": "interaction_test_l16",
                "status": "completed",
                "steps": [
                    {
                        "type": "model_output",
                        "content": [
                            {
                                "type": "audio",
                                "data": "\(base64PCM)",
                                "mime_type": "audio/l16",
                                "sample_rate": 16000,
                                "channels": 1
                            }
                        ]
                    }
                ]
            }
            """.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, mockJSON)
        }

        let buffer = try await provider.synthesize(text: "Test L16 audio", voiceID: "Puck")
        #expect(buffer.frameLength > 0)
        #expect(buffer.format.sampleRate == 16000.0, "Must honor returned sample_rate metadata (16kHz)")
        #expect(buffer.format.channelCount == 1)
    }

    @Test("Gemini TTS fails explicitly when model_output contains no audio content block")
    func test_gemini_tts_missing_audio_block_fails_explicitly() async throws {
        let vault = MockCredentialVault(initialValues: [.gemini: "AIzaSyTestValidFormatKey1234"])
        let provider = GeminiTTSProvider(vault: vault)

        TestURLProtocol.reset()
        defer { TestURLProtocol.reset() }

        TestURLProtocol.registerHandler(for: "generativelanguage.googleapis.com") { req in
            let mockJSON = """
            {
                "id": "interaction_no_audio",
                "status": "completed",
                "steps": [
                    {
                        "type": "model_output",
                        "content": [
                            {
                                "type": "text",
                                "text": "Model produced text instead of audio"
                            }
                        ]
                    }
                ]
            }
            """.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, mockJSON)
        }

        do {
            _ = try await provider.synthesize(text: "Hello", voiceID: "Puck")
            #expect(Bool(false), "Must fail when no audio content block exists")
        } catch let SynthesisError.synthesisFailed(msg) {
            #expect(msg.contains("contained no audio content block"), "Actionable error: \(msg)")
        }
    }

    @Test("Gemini TTS fails explicitly when response contains no model_output step")
    func test_gemini_tts_missing_model_output_fails_explicitly() async throws {
        let vault = MockCredentialVault(initialValues: [.gemini: "AIzaSyTestValidFormatKey1234"])
        let provider = GeminiTTSProvider(vault: vault)

        TestURLProtocol.reset()
        defer { TestURLProtocol.reset() }

        TestURLProtocol.registerHandler(for: "generativelanguage.googleapis.com") { req in
            let mockJSON = """
            {
                "id": "interaction_no_output",
                "status": "completed",
                "steps": [
                    {
                        "type": "user_input",
                        "content": [
                            {
                                "type": "text",
                                "text": "User input"
                            }
                        ]
                    }
                ]
            }
            """.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, mockJSON)
        }

        do {
            _ = try await provider.synthesize(text: "Hello", voiceID: "Puck")
            #expect(Bool(false), "Must fail when no model_output step exists")
        } catch let SynthesisError.synthesisFailed(msg) {
            #expect(msg.contains("contained no 'model_output' step"), "Actionable error: \(msg)")
        }
    }

    @Test("Gemini TTS fails explicitly when audio base64 is invalid")
    func test_gemini_tts_invalid_base64_fails_explicitly() async throws {
        let vault = MockCredentialVault(initialValues: [.gemini: "AIzaSyTestValidFormatKey1234"])
        let provider = GeminiTTSProvider(vault: vault)

        TestURLProtocol.reset()
        defer { TestURLProtocol.reset() }

        TestURLProtocol.registerHandler(for: "generativelanguage.googleapis.com") { req in
            let mockJSON = """
            {
                "id": "interaction_bad_b64",
                "status": "completed",
                "steps": [
                    {
                        "type": "model_output",
                        "content": [
                            {
                                "type": "audio",
                                "data": "???invalid-base64???",
                                "mime_type": "audio/wav"
                            }
                        ]
                    }
                ]
            }
            """.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, mockJSON)
        }

        do {
            _ = try await provider.synthesize(text: "Hello", voiceID: "Puck")
            #expect(Bool(false), "Must fail when base64 is malformed")
        } catch let SynthesisError.synthesisFailed(msg) {
            #expect(msg.contains("invalid base64"), "Actionable error: \(msg)")
        }
    }

    @Test("Gemini TTS fails explicitly when MIME type is unsupported")
    func test_gemini_tts_unsupported_mime_fails_explicitly() async throws {
        let vault = MockCredentialVault(initialValues: [.gemini: "AIzaSyTestValidFormatKey1234"])
        let provider = GeminiTTSProvider(vault: vault)

        TestURLProtocol.reset()
        defer { TestURLProtocol.reset() }

        TestURLProtocol.registerHandler(for: "generativelanguage.googleapis.com") { req in
            let mockJSON = """
            {
                "id": "interaction_bad_mime",
                "status": "completed",
                "steps": [
                    {
                        "type": "model_output",
                        "content": [
                            {
                                "type": "audio",
                                "data": "dGVzdGF1ZGlv",
                                "mime_type": "audio/flac"
                            }
                        ]
                    }
                ]
            }
            """.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, mockJSON)
        }

        do {
            _ = try await provider.synthesize(text: "Hello", voiceID: "Puck")
            #expect(Bool(false), "Must fail when MIME type is unsupported")
        } catch let SynthesisError.synthesisFailed(msg) {
            #expect(msg.contains("Unsupported Gemini audio MIME type"), "Actionable error: \(msg)")
        }
    }

    @Test("Gemini TTS decodes audio block with explicit WAV MIME")
    func test_gemini_tts_wav_mime_succeeds() async throws {
        let vault = MockCredentialVault(initialValues: [.gemini: "AIzaSyTestValidFormatKey1234"])
        let provider = GeminiTTSProvider(vault: vault)

        TestURLProtocol.reset()
        defer { TestURLProtocol.reset() }

        var rawPCM = Data()
        for i in 0..<2400 {
            var sample = Int16(sin(Double(i) * 0.1) * 10000.0).littleEndian
            rawPCM.append(Data(bytes: &sample, count: 2))
        }
        let wavData = AudioBufferUtils.wrapPCM16InWAV(pcmData: rawPCM, sampleRate: 24000, channels: 1)
        let base64Audio = wavData.base64EncodedString()

        TestURLProtocol.registerHandler(for: "generativelanguage.googleapis.com") { req in
            let mockJSON = """
            {
                "id": "interaction_wav_mime",
                "status": "completed",
                "steps": [
                    {
                        "type": "model_output",
                        "content": [
                            {
                                "type": "audio",
                                "data": "\(base64Audio)",
                                "mime_type": "audio/wav",
                                "sample_rate": 24000,
                                "channels": 1
                            }
                        ]
                    }
                ]
            }
            """.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, mockJSON)
        }

        let buffer = try await provider.synthesize(text: "Hello", voiceID: "Puck")
        #expect(buffer.frameLength > 0)
        #expect(buffer.format.sampleRate == 24000.0)
    }

    @Test("Gemini TTS wraps and decodes audio block with raw PCM MIME")
    func test_gemini_tts_raw_pcm_mime_succeeds() async throws {
        let vault = MockCredentialVault(initialValues: [.gemini: "AIzaSyTestValidFormatKey1234"])
        let provider = GeminiTTSProvider(vault: vault)

        TestURLProtocol.reset()
        defer { TestURLProtocol.reset() }

        var rawPCM = Data()
        for i in 0..<2400 {
            var sample = Int16(sin(Double(i) * 0.1) * 10000.0).littleEndian
            rawPCM.append(Data(bytes: &sample, count: 2))
        }
        let base64Audio = rawPCM.base64EncodedString()

        TestURLProtocol.registerHandler(for: "generativelanguage.googleapis.com") { req in
            let mockJSON = """
            {
                "id": "interaction_raw_pcm_mime",
                "status": "completed",
                "steps": [
                    {
                        "type": "model_output",
                        "content": [
                            {
                                "type": "audio",
                                "data": "\(base64Audio)",
                                "mime_type": "audio/l16",
                                "sample_rate": 24000,
                                "channels": 1
                            }
                        ]
                    }
                ]
            }
            """.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, mockJSON)
        }

        let buffer = try await provider.synthesize(text: "Hello", voiceID: "Puck")
        #expect(buffer.frameLength == 2400)
        #expect(buffer.format.sampleRate == 24000.0)
    }

    @Test("Gemini TTS decodes audio block with no MIME but explicit sample rate and channels")
    func test_gemini_tts_no_mime_with_sample_rate_channels_succeeds() async throws {
        let vault = MockCredentialVault(initialValues: [.gemini: "AIzaSyTestValidFormatKey1234"])
        let provider = GeminiTTSProvider(vault: vault)

        TestURLProtocol.reset()
        defer { TestURLProtocol.reset() }

        var rawPCM = Data()
        for i in 0..<2400 {
            var sample = Int16(sin(Double(i) * 0.1) * 10000.0).littleEndian
            rawPCM.append(Data(bytes: &sample, count: 2))
        }
        let base64Audio = rawPCM.base64EncodedString()

        TestURLProtocol.registerHandler(for: "generativelanguage.googleapis.com") { req in
            let mockJSON = """
            {
                "id": "interaction_no_mime_explicit_meta",
                "status": "completed",
                "steps": [
                    {
                        "type": "model_output",
                        "content": [
                            {
                                "type": "audio",
                                "data": "\(base64Audio)",
                                "sample_rate": 24000,
                                "channels": 1
                            }
                        ]
                    }
                ]
            }
            """.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, mockJSON)
        }

        let buffer = try await provider.synthesize(text: "Hello", voiceID: "Puck")
        #expect(buffer.frameLength == 2400)
        #expect(buffer.format.sampleRate == 24000.0)
    }

    @Test("Gemini TTS decodes audio block with RIFF bytes and no MIME")
    func test_gemini_tts_riff_bytes_no_mime_succeeds() async throws {
        let vault = MockCredentialVault(initialValues: [.gemini: "AIzaSyTestValidFormatKey1234"])
        let provider = GeminiTTSProvider(vault: vault)

        TestURLProtocol.reset()
        defer { TestURLProtocol.reset() }

        var rawPCM = Data()
        for i in 0..<2400 {
            var sample = Int16(sin(Double(i) * 0.1) * 10000.0).littleEndian
            rawPCM.append(Data(bytes: &sample, count: 2))
        }
        let wavData = AudioBufferUtils.wrapPCM16InWAV(pcmData: rawPCM, sampleRate: 24000, channels: 1)
        let base64Audio = wavData.base64EncodedString()

        TestURLProtocol.registerHandler(for: "generativelanguage.googleapis.com") { req in
            let mockJSON = """
            {
                "id": "interaction_riff_no_mime",
                "status": "completed",
                "steps": [
                    {
                        "type": "model_output",
                        "content": [
                            {
                                "type": "audio",
                                "data": "\(base64Audio)"
                            }
                        ]
                    }
                ]
            }
            """.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, mockJSON)
        }

        let buffer = try await provider.synthesize(text: "Hello", voiceID: "Puck")
        #expect(buffer.frameLength > 0)
        #expect(buffer.format.sampleRate == 24000.0)
    }

    @Test("Gemini TTS fails explicitly on malformed raw PCM with odd byte count")
    func test_gemini_tts_malformed_raw_pcm_fails() async throws {
        let vault = MockCredentialVault(initialValues: [.gemini: "AIzaSyTestValidFormatKey1234"])
        let provider = GeminiTTSProvider(vault: vault)

        TestURLProtocol.reset()
        defer { TestURLProtocol.reset() }

        // 5 bytes is not aligned to 16-bit (2-byte) linear PCM
        let oddBytes = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let base64Audio = oddBytes.base64EncodedString()

        TestURLProtocol.registerHandler(for: "generativelanguage.googleapis.com") { req in
            let mockJSON = """
            {
                "id": "interaction_malformed_pcm",
                "status": "completed",
                "steps": [
                    {
                        "type": "model_output",
                        "content": [
                            {
                                "type": "audio",
                                "data": "\(base64Audio)",
                                "sample_rate": 24000,
                                "channels": 1
                            }
                        ]
                    }
                ]
            }
            """.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, mockJSON)
        }

        do {
            _ = try await provider.synthesize(text: "Hello", voiceID: "Puck")
            #expect(Bool(false), "Must fail when raw PCM is malformed")
        } catch let SynthesisError.synthesisFailed(msg) {
            #expect(msg.contains("Malformed raw PCM") || msg.contains("not aligned"), "Actionable error: \(msg)")
        }
    }

    // MARK: - BLOCKER 4: Resemble Contract (POST /synthesize with Bearer auth & voice_uuid)

    @Test("Resemble provider calls current /synthesize endpoint with Bearer auth and voice_uuid")
    func test_resemble_contract() async throws {
        let vault = MockCredentialVault(initialValues: [.resemble: "resemble_secret_token_1234"])
        let provider = ResembleProvider(vault: vault)

        TestURLProtocol.reset()
        defer { TestURLProtocol.reset() }

        let testPCM = try createToneBuffer(durationSeconds: 0.2, sampleRate: 44100.0, freq: 440.0)
        let tempWAV = FileManager.default.temporaryDirectory.appendingPathComponent("mock_resemble_\(UUID().uuidString).wav")
        do {
            let file = try AVAudioFile(forWriting: tempWAV, settings: testPCM.format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: testPCM)
        }
        defer { try? FileManager.default.removeItem(at: tempWAV) }

        let wavData = try Data(contentsOf: tempWAV)

        var capturedRequest: URLRequest? = nil
        TestURLProtocol.registerHandler(for: "resemble.ai") { req in
            capturedRequest = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/wav"])!
            return (resp, wavData)
        }

        // Throws if voice_uuid is missing
        await #expect(throws: SynthesisError.self) {
            try await provider.synthesize(text: "Test missing voice_uuid", voiceID: nil)
        }

        // Succeeds with voice_uuid
        let buffer = try await provider.synthesize(text: "Test speech", voiceID: "voice_uuid_fady_123")
        #expect(buffer.frameLength > 0)

        guard let req = capturedRequest, let url = req.url else {
            #expect(Bool(false), "Captured request must exist")
            return
        }

        #expect(url.absoluteString == "https://f.cluster.resemble.ai/synthesize", "Must call current /synthesize endpoint")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer resemble_secret_token_1234", "Must use Bearer auth header")

        if let bodyData = req.httpBody,
           let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            #expect(json["voice_uuid"] as? String == "voice_uuid_fady_123")
            #expect(json["data"] as? String == "Test speech")
        } else {
            #expect(Bool(false), "Request body must contain voice_uuid and data")
        }
    }

    // MARK: - BLOCKER 5 & 6: ElevenLabs Contract & Test Connection

    @Test("ElevenLabs provider clones voice via /v1/voices/add and synthesizes with voice ID")
    func test_elevenlabs_contract_and_cloning() async throws {
        let vault = MockCredentialVault(initialValues: [.elevenLabs: "eleven_key_secret_5678"])
        let provider = ElevenLabsProvider(vault: vault)

        TestURLProtocol.reset()
        defer { TestURLProtocol.reset() }

        var capturedCloneRequest: URLRequest? = nil
        var capturedSynthRequest: URLRequest? = nil

        let testPCM = try createToneBuffer(durationSeconds: 0.2, sampleRate: 44100.0, freq: 440.0)
        let tempRefWAV = FileManager.default.temporaryDirectory.appendingPathComponent("ref_voice_\(UUID().uuidString).wav")
        let tempOutMP3 = FileManager.default.temporaryDirectory.appendingPathComponent("synth_out_\(UUID().uuidString).wav")
        do {
            let file = try AVAudioFile(forWriting: tempRefWAV, settings: testPCM.format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: testPCM)

            let fileOut = try AVAudioFile(forWriting: tempOutMP3, settings: testPCM.format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try fileOut.write(from: testPCM)
        }
        defer {
            try? FileManager.default.removeItem(at: tempRefWAV)
            try? FileManager.default.removeItem(at: tempOutMP3)
        }

        let wavData = try Data(contentsOf: tempOutMP3)

        TestURLProtocol.registerHandler(for: "api.elevenlabs.io") { req in
            if req.url!.path.contains("/v1/voices/add") {
                capturedCloneRequest = req
                let json = "{\"voice_id\": \"cloned_voice_abc_123\"}".data(using: .utf8)!
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (resp, json)
            } else if req.url!.path.contains("/v1/text-to-speech") {
                capturedSynthRequest = req
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/wav"])!
                return (resp, wavData)
            }
            return nil
        }

        // Test cloneVoice
        let clonedID = try await provider.cloneVoice(name: "Fady Voice", audioURL: tempRefWAV)
        #expect(clonedID == "cloned_voice_abc_123")
        #expect(capturedCloneRequest?.value(forHTTPHeaderField: "xi-api-key") == "eleven_key_secret_5678")
        #expect(capturedCloneRequest?.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data") == true)

        // Test synthesize with voice ID
        let synthBuffer = try await provider.synthesize(text: "Hello from ElevenLabs", voiceID: clonedID)
        #expect(synthBuffer.frameLength > 0)
        #expect(capturedSynthRequest?.url?.path.contains("cloned_voice_abc_123") == true)
        #expect(capturedSynthRequest?.value(forHTTPHeaderField: "xi-api-key") == "eleven_key_secret_5678")

        if let synthBody = capturedSynthRequest?.httpBody,
           let json = try? JSONSerialization.jsonObject(with: synthBody) as? [String: Any] {
            #expect(json["model_id"] as? String == "eleven_multilingual_v2", "Must default to eleven_multilingual_v2")
        } else {
            #expect(Bool(false), "Synthesis request body must be valid JSON with model_id")
        }
    }

    @Test("Provider Settings Test Connection sends correct auth headers for all providers")
    @MainActor
    func test_provider_settings_test_connection_headers() async throws {
        let vault = MockCredentialVault(initialValues: [
            .gemini: "test_gemini_key",
            .elevenLabs: "test_eleven_key",
            .resemble: "test_resemble_key"
        ])
        let session = NetworkSessionFactory.makeSession()
        let settingsVM = ProviderSettingsViewModel(vault: vault, session: session)

        TestURLProtocol.reset()
        defer { TestURLProtocol.reset() }

        var capturedGemini: URLRequest? = nil
        var capturedEleven: URLRequest? = nil
        var capturedResemble: URLRequest? = nil

        TestURLProtocol.registerHandler(for: "generativelanguage.googleapis.com") { req in
            capturedGemini = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        TestURLProtocol.registerHandler(for: "api.elevenlabs.io") { req in
            capturedEleven = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        TestURLProtocol.registerHandler(for: "app.resemble.ai") { req in
            capturedResemble = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        settingsVM.testGeminiConnection()
        settingsVM.testElevenLabsConnection()
        settingsVM.testResembleConnection()

        // Allow background async tasks to execute
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(capturedGemini?.value(forHTTPHeaderField: "x-goog-api-key") == "test_gemini_key")
        #expect(capturedEleven?.value(forHTTPHeaderField: "xi-api-key") == "test_eleven_key")
        #expect(capturedResemble?.value(forHTTPHeaderField: "Authorization") == "Bearer test_resemble_key")
    }

    // MARK: - BLOCKER 7: >8% Overflow Invariant & Preview/Export Protection

    struct OverflowMockSynthesizer: VoiceSynthesisProvider, Sendable {
        let providerType: SynthesisProviderType = .pocketTTS
        let durationSec: Double

        func synthesize(
            text: String,
            voiceID: String? = nil,
            referenceAudioURL: URL? = nil
        ) async throws -> AVAudioPCMBuffer {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 1) else {
                throw NSError(domain: "Test", code: 1)
            }
            let frameCount = AVAudioFrameCount(round(durationSec * 44100.0))
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
            buf.frameLength = frameCount
            let channel = buf.floatChannelData![0]
            for i in 0..<Int(frameCount) {
                channel[i] = Float(sin(2.0 * .pi * 1200.0 * Double(i) / 44100.0)) * 0.5 // Distinct 1200Hz tone
            }
            return buf
        }
    }

    @Test("Duration overflow >8% is gated as candidate and strictly excluded from preview and export")
    @MainActor
    func test_duration_overflow_gated_not_in_preview_or_export() async throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceURL = tempDir.appendingPathComponent("multi_source.mov")
        let asset = try await Fixture2MultiTrack.generate(at: sourceURL)
        let narrationTrackID = asset.audioTrackIDs[0]

        let appVM = AppViewModel()
        try await appVM.importMediaAsync(from: sourceURL)
        appVM.designatedNarrationID = Int(narrationTrackID)
        appVM.cues = asset.expectedCues

        // Cue 1 is 2.5s (1.0s .. 3.5s).
        // Synthesize 4.0s speech (+60% overflow >> 8%)
        let overflowSynth = OverflowMockSynthesizer(durationSec: 4.0)
        let cue1ID = appVM.cues[0].id
        try await appVM.synthesizeCue(id: cue1ID, customProvider: overflowSynth)

        // Verify Cue 1 editState is .overflowGated
        let cue1 = appVM.cues.first { $0.id == cue1ID }!
        #expect(cue1.editState == .overflowGated)
        #expect(cue1.audioWAVRelativePath == nil, "Active replacement audio must be nil for overflowGated cue")
        #expect(cue1.candidateAudioWAVRelativePath != nil, "Candidate audio path must be stored for inspection")
        #expect(cue1.overflowDelta != nil)

        // 1. Verify Preview Composition does NOT play the 1200Hz candidate audio
        let comp = try await appVM.buildPreviewComposition()
        let audioTracks = try await comp.loadTracks(withMediaType: .audio)
        let extractor = AudioTrackExtractor()
        let previewPCM = try await extractor.extractPCMBuffer(
            from: comp,
            trackID: audioTracks.last!.trackID,
            targetSampleRate: 16000.0
        )
        let cue1Crossings = countZeroCrossings(in: previewPCM, startSec: 1.5, durationSec: 1.0)
        // Original Cue 1 audio is 440Hz (~880 crossings). Candidate was 1200Hz (~2400 crossings).
        #expect(cue1Crossings < 1200, "Preview must NOT play candidate audio; must keep original 440Hz narration (got \(cue1Crossings) crossings)")

        // 2. Verify Passthrough Export does NOT export the candidate audio
        let exportURL = tempDir.appendingPathComponent("export_overflow.mov")
        let pipeline = PassthroughExportPipeline()
        let config = PassthroughExportConfig(
            sourceURL: sourceURL,
            destinationURL: exportURL,
            designatedNarrationTrackID: narrationTrackID,
            passthroughTrackIDs: [],
            cues: appVM.cues,
            bundleRootURL: appVM.sessionWorkingDir
        )
        let exportResult = try await pipeline.export(config: config, progress: nil)
        #expect(FileManager.default.fileExists(atPath: exportResult.outputURL.path))

        let exportedAsset = AVURLAsset(url: exportURL)
        let exportedTracks = try await exportedAsset.loadTracks(withMediaType: .audio)
        let exportedPCM = try await extractor.extractPCMBuffer(
            from: exportedAsset,
            trackID: exportedTracks[0].trackID,
            targetSampleRate: 16000.0
        )
        let exportedCue1Crossings = countZeroCrossings(in: exportedPCM, startSec: 1.5, durationSec: 1.0)
        #expect(exportedCue1Crossings < 1200, "Export must NOT include candidate audio; must keep original narration (got \(exportedCue1Crossings) crossings)")

        // 3. User explicitly approves Force Fit
        try await appVM.forceFitCue(id: cue1ID)
        let cue1Fitted = appVM.cues.first { $0.id == cue1ID }!
        #expect(cue1Fitted.editState == .forceFitted)
        #expect(cue1Fitted.audioWAVRelativePath != nil, "Active replacement audio must now be set after Force Fit")
        #expect(cue1Fitted.candidateAudioWAVRelativePath == nil)

        // Verify preview now plays the fitted replacement audio (1200Hz -> ~2400 crossings)
        let fittedComp = try await appVM.buildPreviewComposition()
        let fittedTracks = try await fittedComp.loadTracks(withMediaType: .audio)
        let fittedPCM = try await extractor.extractPCMBuffer(
            from: fittedComp,
            trackID: fittedTracks.last!.trackID,
            targetSampleRate: 16000.0
        )
        let fittedCue1Crossings = countZeroCrossings(in: fittedPCM, startSec: 1.5, durationSec: 1.0)
        #expect(fittedCue1Crossings >= 2100, "After Force Fit, preview must play replacement audio (got \(fittedCue1Crossings) crossings)")
    }

    // MARK: - BLOCKER 8: MOV Only Export Enforcement

    @Test("Export pipeline strictly enforces QuickTime Movie (.mov) container format")
    func test_export_enforces_mov_only() async throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceURL = tempDir.appendingPathComponent("source.mov")
        let asset = try await Fixture1SingleTrack.generate(at: sourceURL)

        let pipeline = PassthroughExportPipeline()

        // 1. Attempting to export with .mp4 MUST fail with actionable error
        let mp4URL = tempDir.appendingPathComponent("output.mp4")
        let invalidConfig = PassthroughExportConfig(
            sourceURL: sourceURL,
            destinationURL: mp4URL,
            designatedNarrationTrackID: asset.audioTrackIDs[0],
            passthroughTrackIDs: [],
            cues: asset.expectedCues
        )
        await #expect(throws: ExportError.self) {
            _ = try await pipeline.export(config: invalidConfig)
        }

        // 2. Exporting with .mov succeeds and produces valid QuickTime container
        let movURL = tempDir.appendingPathComponent("output.mov")
        let validConfig = PassthroughExportConfig(
            sourceURL: sourceURL,
            destinationURL: movURL,
            designatedNarrationTrackID: asset.audioTrackIDs[0],
            passthroughTrackIDs: [],
            cues: asset.expectedCues
        )
        let result = try await pipeline.export(config: validConfig)
        #expect(FileManager.default.fileExists(atPath: movURL.path))
        #expect(result.outputURL.pathExtension.lowercased() == "mov")
    }

    // MARK: - BLOCKER 1 & 14: Reference Voice & Project Persistence

    @Test("Reference Voice and provider identifiers survive project save and reload")
    @MainActor
    func test_reference_voice_and_persistence_roundtrip() async throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceURL = tempDir.appendingPathComponent("multi_source.mov")
        _ = try await Fixture2MultiTrack.generate(at: sourceURL)

        let appVM = AppViewModel()
        try await appVM.importMediaAsync(from: sourceURL)

        // Create reference audio
        let refAudioURL = tempDir.appendingPathComponent("fady_clean_speech.wav")
        let refPCM = try createToneBuffer(durationSeconds: 1.0, freq: 300.0)
        try writeBufferToWAV(refPCM, to: refAudioURL)

        // Configure Reference Voice in appViewModel
        try appVM.setReferenceVoice(name: "Fady Voice", audioURL: refAudioURL)
        appVM.referenceVoice?.elevenLabsVoiceID = "eleven_voice_fady_abc"
        appVM.setResembleVoiceUUID("resemble_uuid_fady_xyz")
        appVM.selectedProviderType = .elevenLabs
        appVM.timelineViewModel.clock.frameRate = 24.0

        // Save project bundle
        let bundleURL = tempDir.appendingPathComponent("TestProject.voicefix")
        try appVM.saveProject(to: bundleURL)
        #expect(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("project.json").path))
        #expect(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("voice").path))

        // Create fresh AppViewModel and reload
        let loadedVM = AppViewModel()
        try loadedVM.loadProject(from: bundleURL)

        // Assert all states survived
        #expect(loadedVM.referenceVoice != nil)
        #expect(loadedVM.referenceVoice?.name == "Fady Voice")
        #expect(loadedVM.referenceVoice?.elevenLabsVoiceID == "eleven_voice_fady_abc")
        #expect(loadedVM.referenceVoice?.resembleVoiceUUID == "resemble_uuid_fady_xyz")
        #expect(loadedVM.selectedProviderType == .elevenLabs)
        #expect(loadedVM.timelineViewModel.clock.frameRate == 24.0)

        // Verify no secrets leaked into project.json
        let projectJSONData = try Data(contentsOf: bundleURL.appendingPathComponent("project.json"))
        let jsonStr = String(data: projectJSONData, encoding: .utf8)!
        #expect(!jsonStr.contains("AIzaSy"))
        #expect(!jsonStr.contains("secret"))
        #expect(!jsonStr.contains("Bearer"))
    }

    // MARK: - BLOCKER 9: Loudness Normalization & Boundary Matching

    @Test("DurationFitter matches loudness of synthesized buffer against original reference audio")
    func test_duration_fitter_loudness_matching() throws {
        let fitter = DurationFitter()
        let normalizer = LoudnessNormalizer()
        let targetDuration = CMTime(seconds: 1.0, preferredTimescale: 600_000)

        // Quiet synthesized buffer (amplitude 0.05)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 1) else {
            throw NSError(domain: "Test", code: 1)
        }
        let frameCount = AVAudioFrameCount(44100)
        let quietBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        quietBuffer.frameLength = frameCount
        let quietChannel = quietBuffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            quietChannel[i] = Float(sin(2.0 * .pi * 440.0 * Double(i) / 44100.0)) * 0.05
        }

        // Louder reference buffer (amplitude 0.5)
        let refBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        refBuffer.frameLength = frameCount
        let refChannel = refBuffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            refChannel[i] = Float(sin(2.0 * .pi * 440.0 * Double(i) / 44100.0)) * 0.5
        }

        let quietLUFS = try normalizer.measureLUFS(buffer: quietBuffer)
        let refLUFS = try normalizer.measureLUFS(buffer: refBuffer)
        #expect(refLUFS > quietLUFS + 15.0, "Reference buffer should be significantly louder than quiet buffer")

        let result = try fitter.fit(
            synthesizedAudio: quietBuffer,
            targetDuration: targetDuration,
            roomToneBuffer: nil,
            referenceAudioBuffer: refBuffer,
            forceCompress: false
        )

        guard case .fitted(let outputBuffer) = result else {
            #expect(Bool(false), "Result should be fitted")
            return
        }

        let outputLUFS = try normalizer.measureLUFS(buffer: outputBuffer)
        #expect(outputLUFS > quietLUFS + 10.0, "Fitted audio loudness should be boosted to match reference")
        #expect(abs(outputLUFS - refLUFS) < 2.5, "Fitted audio loudness should closely match reference LUFS (got \(outputLUFS), expected ~\(refLUFS))")
    }

    // MARK: - Custom Provider Reference Audio & Voice ID Forwarding

    final class MockTrackingSynthesizer: VoiceSynthesisProvider, @unchecked Sendable {
        let providerType: SynthesisProviderType
        var receivedText: String?
        var receivedVoiceID: String?
        var receivedRefURL: URL?

        init(providerType: SynthesisProviderType) {
            self.providerType = providerType
        }

        func synthesize(
            text: String,
            voiceID: String? = nil,
            referenceAudioURL: URL? = nil
        ) async throws -> AVAudioPCMBuffer {
            self.receivedText = text
            self.receivedVoiceID = voiceID
            self.receivedRefURL = referenceAudioURL

            guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 1) else {
                throw NSError(domain: "Test", code: 1)
            }
            let frameCount = AVAudioFrameCount(44100)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
            buf.frameLength = frameCount
            return buf
        }
    }

    @Test("AppViewModel forwards reference audio URL and provider voice IDs to synthesis providers")
    @MainActor
    func test_custom_provider_receives_voice_id_and_reference_audio() async throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let appVM = AppViewModel()
        let cueID = UUID()
        let testCue = Cue(
            id: cueID,
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 1.0, preferredTimescale: 600)),
            text: "Testing provider wiring"
        )
        appVM.cues = [testCue]

        // Create reference voice file
        let refURL = tempDir.appendingPathComponent("speaker.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 1)!
        let refBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
        refBuffer.frameLength = 44100
        try writeBufferToWAV(refBuffer, to: refURL)

        try appVM.setReferenceVoice(name: "Test Voice", audioURL: refURL)
        appVM.setElevenLabsVoiceID("eleven_id_999")
        appVM.setResembleVoiceUUID("resemble_uuid_888")

        // 1. Test PocketTTS forwards referenceAudioURL
        let pocketMock = MockTrackingSynthesizer(providerType: .pocketTTS)
        try await appVM.synthesizeCue(id: cueID, providerType: .pocketTTS, customProvider: pocketMock)
        #expect(pocketMock.receivedRefURL != nil, "PocketTTS must receive referenceAudioURL")
        #expect(pocketMock.receivedRefURL?.lastPathComponent.contains("reference_voice") == true)

        // 2. Test ElevenLabs forwards elevenLabsVoiceID
        let elevenMock = MockTrackingSynthesizer(providerType: .elevenLabs)
        try await appVM.synthesizeCue(id: cueID, providerType: .elevenLabs, customProvider: elevenMock)
        #expect(elevenMock.receivedVoiceID == "eleven_id_999", "ElevenLabs must receive elevenLabsVoiceID")

        // 3. Test Resemble forwards resembleVoiceUUID
        let resembleMock = MockTrackingSynthesizer(providerType: .resemble)
        try await appVM.synthesizeCue(id: cueID, providerType: .resemble, customProvider: resembleMock)
        #expect(resembleMock.receivedVoiceID == "resemble_uuid_888", "Resemble must receive resembleVoiceUUID")
    }

    // MARK: - Setting Voice IDs When Reference Voice is Nil

    @Test("Setting ElevenLabs Voice ID initializes ReferenceVoice when nil")
    @MainActor
    func test_set_elevenlabs_voice_id_when_reference_voice_nil() {
        let appVM = AppViewModel()
        #expect(appVM.referenceVoice == nil)

        appVM.setElevenLabsVoiceID("eleven_new_id")
        #expect(appVM.referenceVoice != nil)
        #expect(appVM.referenceVoice?.elevenLabsVoiceID == "eleven_new_id")
    }

    // MARK: - Updating Cue Text Clears Overflow

    @Test("Updating cue text clears pending overflow candidate and delta")
    func test_updating_cue_text_clears_overflow_delta_and_candidate() {
        let cue = Cue(
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 2.0, preferredTimescale: 600)),
            text: "Original text that overflowed",
            candidateAudioWAVRelativePath: "audio/cues/candidate_123.wav",
            editState: .overflowGated,
            overflowDelta: CMTime(seconds: 0.5, preferredTimescale: 600)
        )
        #expect(cue.candidateAudioWAVRelativePath != nil)
        #expect(cue.overflowDelta != nil)

        let updated = cue.withUpdatedText("Shorter text to fit")
        #expect(updated.text == "Shorter text to fit")
        #expect(updated.candidateAudioWAVRelativePath == nil, "Candidate audio must be cleared upon text update")
        #expect(updated.overflowDelta == nil, "Overflow delta must be cleared upon text update")
        #expect(updated.editState == .edited)
    }

    // MARK: - AudioTrackExtractor timeRange sub-slice extraction

    @Test("AudioTrackExtractor extracts sub-slice matching timeRange accurately")
    func test_audio_track_extractor_time_range() async throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceURL = tempDir.appendingPathComponent("slice_test.mov")
        let asset = try await Fixture1SingleTrack.generate(at: sourceURL)
        let trackID = asset.audioTrackIDs[0]

        let extractor = AudioTrackExtractor()
        let sliceRange = CMTimeRange(
            start: CMTime(seconds: 2.0, preferredTimescale: 600),
            duration: CMTime(seconds: 1.5, preferredTimescale: 600)
        )
        let pcm = try await extractor.extractPCMBuffer(
            from: AVURLAsset(url: sourceURL),
            trackID: trackID,
            timeRange: sliceRange,
            targetSampleRate: 16000.0,
            targetChannels: 1
        )

        let durationSeconds = Double(pcm.frameLength) / 16000.0
        #expect(abs(durationSeconds - 1.5) < 0.05, "Extracted PCM duration should be ~1.5s, got \(durationSeconds)")
    }

    // MARK: - PocketTTS Provider & Cache Persistence Across Cues

    @Test("PocketTTS caches voice clone and reuses embedding across repeated cue synthesis")
    @MainActor
    func test_pockettts_repeated_synthesis_caches_voice_clone() async throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let appVM = AppViewModel()
        let refURL = tempDir.appendingPathComponent("speaker.wav")
        let tone = try createToneBuffer(durationSeconds: 0.5, sampleRate: 24000.0, freq: 440.0)
        try writeBufferToWAV(tone, to: refURL)

        try appVM.setReferenceVoice(name: "Test Voice", audioURL: refURL)
        #expect(appVM.referenceVoice?.pocketTTSStatus == .configured)

        let cue1 = Cue(
            id: UUID(),
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 1.0, preferredTimescale: 600)),
            text: "First cue to synthesize"
        )
        let cue2 = Cue(
            id: UUID(),
            timeRange: CMTimeRange(start: CMTime(seconds: 1.0, preferredTimescale: 600), duration: CMTime(seconds: 1.0, preferredTimescale: 600)),
            text: "Second cue to synthesize"
        )
        appVM.cues = [cue1, cue2]

        var synthInvocationCount = 0

        // Configure test spy engine on appVM's persistent PocketTTSProvider
        let spyEngine = SpyPocketTTSEngine()
        appVM.providerRegistry.pocketTTS.setEngine(spyEngine)

        spyEngine.cloneHandler = { url in
            return PocketTTSVoiceHandle(identifier: url.lastPathComponent)
        }
        spyEngine.synthesizeHandleHandler = { text, voiceHandle in
            synthInvocationCount += 1
            let buf = try self.createToneBuffer(durationSeconds: 0.3, sampleRate: 24000.0, freq: 440.0)
            let outWav = tempDir.appendingPathComponent("out_\(synthInvocationCount).wav")
            try self.writeBufferToWAV(buf, to: outWav)
            return try Data(contentsOf: outWav)
        }

        // Synthesize first cue: should invoke cloneVoice once
        try await appVM.synthesizeCue(id: cue1.id, providerType: .pocketTTS)
        #expect(spyEngine.cloneCalls.count == 1, "First synthesis must clone voice")
        #expect(synthInvocationCount == 1)
        #expect(appVM.providerRegistry.pocketTTS.cloneCount == 1)
        #expect(appVM.referenceVoice?.pocketTTSStatus == .ready)

        // Synthesize second cue: must REUSE cached voice clone without calling cloneVoice again!
        try await appVM.synthesizeCue(id: cue2.id, providerType: .pocketTTS)
        #expect(spyEngine.cloneCalls.count == 1, "Second synthesis must REUSE cached clone, not clone again")
        #expect(synthInvocationCount == 2)
        #expect(appVM.providerRegistry.pocketTTS.cloneCount == 1, "cloneCount must remain 1")
        #expect(appVM.referenceVoice?.pocketTTSStatus == .ready)

        // Now update reference voice: must invalidate cache and re-clone on next synthesis
        let refURL2 = tempDir.appendingPathComponent("speaker2.wav")
        try writeBufferToWAV(tone, to: refURL2)
        try appVM.setReferenceVoice(name: "Test Voice 2", audioURL: refURL2)
        #expect(appVM.referenceVoice?.pocketTTSStatus == .configured)

        try await appVM.synthesizeCue(id: cue1.id, providerType: .pocketTTS)
        #expect(spyEngine.cloneCalls.count == 2, "Synthesis after new voice import must re-clone")
        #expect(appVM.providerRegistry.pocketTTS.cloneCount == 2)
    }

    // MARK: - Provider Selection Single Source of Truth & Bundle Persistence

    @Test("Provider selection has single source of truth and roundtrips through project bundle")
    @MainActor
    func test_provider_selection_single_source_of_truth_persistence() async throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mockCueGen = CueGenerator(
            silenceDetector: EnergySilenceDetector(minSilenceDuration: 0.2, speechPadding: 0.05, energyThresholdDB: -40.0),
            transcriptionService: MockTranscriptionService()
        )
        let appVM = AppViewModel(cueGenerator: mockCueGen)
        let sourceURL = tempDir.appendingPathComponent("source.mov")
        _ = try await Fixture1SingleTrack.generate(at: sourceURL)
        try await appVM.importMediaAsync(from: sourceURL)

        // Verify initial state
        #expect(appVM.selectedProviderType == .pocketTTS)
        #expect(appVM.scriptEditorViewModel.selectedProvider == .pocketTTS)

        // Update via ScriptEditorViewModel proxy: must directly update AppViewModel stored property
        appVM.scriptEditorViewModel.selectedProvider = .elevenLabs
        #expect(appVM.selectedProviderType == .elevenLabs)
        #expect(appVM.scriptEditorViewModel.selectedProvider == .elevenLabs)

        // Update via AppViewModel stored property: must immediately reflect in ScriptEditorViewModel proxy
        appVM.selectedProviderType = .geminiTTS
        #expect(appVM.scriptEditorViewModel.selectedProvider == .geminiTTS)

        // Save project
        let bundleURL = tempDir.appendingPathComponent("TestBundle.voicefix")
        try appVM.saveProject(to: bundleURL)

        // Load into a fresh AppViewModel
        let freshVM = AppViewModel()
        #expect(freshVM.selectedProviderType == .pocketTTS)
        try freshVM.loadProject(from: bundleURL)

        #expect(freshVM.selectedProviderType == .geminiTTS, "Loaded bundle must restore active provider type")
        #expect(freshVM.scriptEditorViewModel.selectedProvider == .geminiTTS, "ScriptEditor proxy must match loaded provider type")
    }

    // MARK: - PassthroughExportPipeline Ignored Track Exclusion

    @Test("PassthroughExportPipeline excludes ignored tracks both with and without edited cues")
    func test_passthrough_export_excludes_ignored_tracks_with_and_without_edited_cues() async throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Generate 3-track synthetic movie (Track 1: Narration, Track 2: Passthrough, Track 3: Ignored)
        let sourceURL = tempDir.appendingPathComponent("source_3tracks.mov")
        let asset = try await SyntheticFixtureGenerator.createMovie(
            at: sourceURL,
            duration: CMTime(seconds: 2.0, preferredTimescale: 600),
            audioTracks: [
                SyntheticAudioTrackSpec(trackName: "Narration", segments: [.sineTone(frequency: 440.0, duration: CMTime(seconds: 2.0, preferredTimescale: 600))]),
                SyntheticAudioTrackSpec(trackName: "Music", segments: [.sineTone(frequency: 880.0, duration: CMTime(seconds: 2.0, preferredTimescale: 600))]),
                SyntheticAudioTrackSpec(trackName: "IgnoredSFX", segments: [.noise(amplitude: 0.2, duration: CMTime(seconds: 2.0, preferredTimescale: 600))])
            ]
        )
        #expect(asset.audioTrackIDs.count == 3)
        let narrationID = Int(asset.audioTrackIDs[0])
        let passthroughID = Int(asset.audioTrackIDs[1])

        let pipeline = PassthroughExportPipeline()

        // CASE A: Without edited cues (hasEditedAudio = false)
        let uneditedCues = [
            Cue(
                timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 2.0, preferredTimescale: 600)),
                text: "Unedited narration",
                audioWAVRelativePath: nil,
                editState: .original
            )
        ]
        let outURLUnedited = tempDir.appendingPathComponent("exported_unedited.mov")
        let configUnedited = PassthroughExportConfig(
            sourceURL: sourceURL,
            destinationURL: outURLUnedited,
            designatedNarrationTrackID: CMPersistentTrackID(narrationID),
            passthroughTrackIDs: [CMPersistentTrackID(passthroughID)],
            cues: uneditedCues,
            bundleRootURL: tempDir
        )

        _ = try await pipeline.export(config: configUnedited)

        let exportedAssetUnedited = AVURLAsset(url: outURLUnedited)
        let audioTracksUnedited = try await exportedAssetUnedited.loadTracks(withMediaType: .audio)
        #expect(audioTracksUnedited.count == 2, "Export without edited cues must contain exactly 2 audio tracks, excluding ignored track")

        // CASE B: With edited cues (hasEditedAudio = true)
        let tone = try createToneBuffer(durationSeconds: 2.0, sampleRate: 24000.0, freq: 550.0)
        let cueWAVURL = tempDir.appendingPathComponent("audio/cues/cue_1.wav")
        try writeBufferToWAV(tone, to: cueWAVURL)

        let editedCues = [
            Cue(
                timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 2.0, preferredTimescale: 600)),
                text: "Edited narration",
                audioWAVRelativePath: "audio/cues/cue_1.wav",
                editState: .synthesized
            )
        ]
        let outURLEdited = tempDir.appendingPathComponent("exported_edited.mov")
        let configEdited = PassthroughExportConfig(
            sourceURL: sourceURL,
            destinationURL: outURLEdited,
            designatedNarrationTrackID: CMPersistentTrackID(narrationID),
            passthroughTrackIDs: [CMPersistentTrackID(passthroughID)],
            cues: editedCues,
            bundleRootURL: tempDir
        )

        _ = try await pipeline.export(config: configEdited)

        let exportedAssetEdited = AVURLAsset(url: outURLEdited)
        let audioTracksEdited = try await exportedAssetEdited.loadTracks(withMediaType: .audio)
        #expect(audioTracksEdited.count == 2, "Export with edited cues must contain exactly 2 audio tracks, excluding ignored track")
    }

    // MARK: - Reference Voice Canonicalization & Lifecycle Semantics

    @Test("Reference Voice canonicalization creates 24kHz mono WAV and enforces correct state semantics")
    @MainActor
    func test_reference_voice_canonicalization_and_status_lifecycle() async throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let appVM = AppViewModel()
        #expect(appVM.referenceVoice == nil)

        // Create a 44.1kHz stereo audio file to import
        let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 2)!
        let stereoBuf = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 44100)!
        stereoBuf.frameLength = 44100
        let sourceURL = tempDir.appendingPathComponent("raw_input.aiff")
        try writeBufferToWAV(stereoBuf, to: sourceURL)

        // Import reference voice
        try appVM.setReferenceVoice(name: "My Voice", audioURL: sourceURL)

        guard let ref = appVM.referenceVoice else {
            #expect(Bool(false), "referenceVoice must be non-nil after import")
            return
        }

        #expect(ref.name == "My Voice")
        #expect(ref.pocketTTSStatus == .configured, "Status must be .configured upon import, NOT .ready")
        #expect(ref.audioRelativePath == "voice/reference_voice.wav", "Relative path must be canonical .wav")

        // Verify file on disk is valid 24kHz mono WAV
        let diskURL = appVM.sessionWorkingDir.appendingPathComponent(ref.audioRelativePath)
        let diskFile = try AVAudioFile(forReading: diskURL)
        #expect(diskFile.fileFormat.sampleRate == 24000.0)
        #expect(diskFile.fileFormat.channelCount == 1)

        // Test status transition during synthesis
        let cueID = UUID()
        appVM.cues = [Cue(id: cueID, timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 1.0, preferredTimescale: 600)), text: "Hi")]

        let spyEngine = SpyPocketTTSEngine()
        appVM.providerRegistry.pocketTTS.setEngine(spyEngine)

        spyEngine.cloneHandler = { _ in
            let status = await MainActor.run { appVM.referenceVoice?.pocketTTSStatus }
            #expect(status == .loading, "Status must be .loading during synthesis")
            return PocketTTSVoiceHandle(identifier: "test-voice")
        }
        spyEngine.synthesizeHandleHandler = { _, _ in
            let tone = try self.createToneBuffer(durationSeconds: 0.2, sampleRate: 24000.0, freq: 440.0)
            let outW = tempDir.appendingPathComponent("syn.wav")
            try self.writeBufferToWAV(tone, to: outW)
            return try Data(contentsOf: outW)
        }

        try await appVM.synthesizeCue(id: cueID, providerType: .pocketTTS)
        #expect(appVM.referenceVoice?.pocketTTSStatus == .ready, "Status must be .ready after successful synthesis")

        // Test failure transitions to .failed
        spyEngine.synthesizeHandleHandler = { _, _ in
            throw NSError(domain: "Test", code: 999, userInfo: [NSLocalizedDescriptionKey: "Core ML failure"])
        }
        do {
            try await appVM.synthesizeCue(id: cueID, providerType: .pocketTTS)
            #expect(Bool(false), "Expected synthesis to fail")
        } catch {
            #expect(appVM.referenceVoice?.pocketTTSStatus == .failed, "Status must be .failed after failed synthesis")
        }
    }
}
