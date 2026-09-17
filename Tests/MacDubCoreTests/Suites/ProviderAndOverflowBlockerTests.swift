import Testing
import AVFoundation
import CoreMedia
import Foundation
@testable import MacDubCore
@testable import MacDubApp

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

    // MARK: - BLOCKER 3: Gemini TTS Contract (gemini-3.1-flash-tts-preview & response_format)

    @Test("Gemini TTS uses current audio model and header-based authentication")
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
        #expect(url.path.contains("gemini-3.1-flash-tts-preview"), "Must use current Gemini TTS model: \(url.path)")
        #expect(req.value(forHTTPHeaderField: "x-goog-api-key") == "AIzaSyTestValidFormatKey1234")

        // Inspect request body contains response_format audio
        if let bodyData = req.httpBody,
           let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
           let genConfig = json["generationConfig"] as? [String: Any],
           let respFormat = genConfig["response_format"] as? [String: Any] {
            #expect(respFormat["type"] as? String == "audio", "Request must specify response_format audio")
        } else {
            #expect(Bool(false), "Request body must contain generationConfig.response_format")
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

        // Test synthesize with voice ID
        let synthBuffer = try await provider.synthesize(text: "Hello from ElevenLabs", voiceID: clonedID)
        #expect(synthBuffer.frameLength > 0)
        #expect(capturedSynthRequest?.url?.path.contains("cloned_voice_abc_123") == true)
        #expect(capturedSynthRequest?.value(forHTTPHeaderField: "xi-api-key") == "eleven_key_secret_5678")
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
        let refFile = try AVAudioFile(forWriting: refAudioURL, settings: refPCM.format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try refFile.write(from: refPCM)

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
}
