import Foundation
import CoreMedia
@preconcurrency import AVFoundation
import FluidAudio

public enum SynthesisProviderType: String, CaseIterable, Sendable, Codable {
    case pocketTTS = "PocketTTS (Local Voice Clone)"
    case elevenLabs = "ElevenLabs (Cloud Clone)"
    case resemble = "Resemble AI (Cloud Clone)"
    case geminiTTS = "Gemini TTS (Prebuilt Natural Voice)"
}

public protocol VoiceSynthesisProvider: Sendable {
    var providerType: SynthesisProviderType { get }
    func synthesize(
        text: String,
        voiceID: String?,
        referenceAudioURL: URL?
    ) async throws -> AVAudioPCMBuffer
}

extension VoiceSynthesisProvider {
    public func synthesize(
        text: String,
        voiceID: String? = nil,
        referenceAudioURL: URL? = nil
    ) async throws -> AVAudioPCMBuffer {
        try await synthesize(text: text, voiceID: voiceID, referenceAudioURL: referenceAudioURL)
    }
}

public enum SynthesisError: Error, LocalizedError, Equatable {
    case missingAPIKey(ServiceKey)
    case invalidReferenceAudio
    case synthesisFailed(String)
    case unsupportedOperation(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let svc):
            return "Missing API key for \(svc.rawValue) in Keychain"
        case .invalidReferenceAudio:
            return "Reference audio for voice cloning is missing or unreadable"
        case .synthesisFailed(let msg):
            return "Voice synthesis failed: \(msg)"
        case .unsupportedOperation(let msg):
            return "Unsupported operation: \(msg)"
        }
    }
}

// MARK: - Audio Buffer Utilities

public enum AudioBufferUtils {
    public static func pcmBuffer(fromAudioData data: Data, fileExtension: String = "wav") throws -> AVAudioPCMBuffer {
        let actualExtension = data.starts(with: "RIFF".utf8) ? "wav" : fileExtension
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(actualExtension)
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let file = try AVAudioFile(forReading: tempURL)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw SynthesisError.synthesisFailed("Failed to decode audio data into PCM buffer")
        }
        try file.read(into: buffer)
        return buffer
    }

    /// Wraps raw 16-bit linear PCM mono samples in a valid 44-byte RIFF WAV header.
    public static func wrapPCM16InWAV(pcmData: Data, sampleRate: Int = 24000, channels: Int = 1) -> Data {
        var wav = Data()
        let totalDataLen = Int32(pcmData.count)
        let totalFileLen = totalDataLen + 36
        let byteRate = Int32(sampleRate * channels * 2)
        let blockAlign = Int16(channels * 2)

        wav.append(contentsOf: "RIFF".utf8)
        var fLen = totalFileLen.littleEndian
        wav.append(Data(bytes: &fLen, count: 4))
        wav.append(contentsOf: "WAVEfmt ".utf8)
        var subchunk1Size = Int32(16).littleEndian
        wav.append(Data(bytes: &subchunk1Size, count: 4))
        var audioFormat = Int16(1).littleEndian // PCM
        wav.append(Data(bytes: &audioFormat, count: 2))
        var ch = Int16(channels).littleEndian
        wav.append(Data(bytes: &ch, count: 2))
        var sRate = Int32(sampleRate).littleEndian
        wav.append(Data(bytes: &sRate, count: 4))
        var bRate = byteRate.littleEndian
        wav.append(Data(bytes: &bRate, count: 4))
        var bAlign = blockAlign.littleEndian
        wav.append(Data(bytes: &bAlign, count: 2))
        var bps = Int16(16).littleEndian
        wav.append(Data(bytes: &bps, count: 2))
        wav.append(contentsOf: "data".utf8)
        var dLen = totalDataLen.littleEndian
        wav.append(Data(bytes: &dLen, count: 4))
        wav.append(pcmData)
        return wav
    }

    /// Canonicalizes any audio file (WAV, MP3, M4A, etc.) to a standard 16-bit mono PCM WAV file at targetSampleRate.
    public static func canonicalizeToWAV(sourceURL: URL, destinationURL: URL, targetSampleRate: Double = 24000) throws {
        let sourceFile = try AVAudioFile(forReading: sourceURL)
        let sourceFormat = sourceFile.processingFormat
        let frameCount = AVAudioFrameCount(sourceFile.length)
        guard frameCount > 0, let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw SynthesisError.synthesisFailed("Failed to read audio file")
        }
        try sourceFile.read(into: sourceBuffer)

        let targetProcessingFormat = AVAudioFormat(standardFormatWithSampleRate: targetSampleRate, channels: 1)!
        let finalBuffer: AVAudioPCMBuffer

        if sourceFormat.sampleRate == targetSampleRate && sourceFormat.channelCount == 1 {
            finalBuffer = sourceBuffer
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetProcessingFormat) else {
                throw SynthesisError.synthesisFailed("Failed to create audio converter from \(sourceFormat) to \(targetProcessingFormat)")
            }
            let ratio = targetSampleRate / sourceFormat.sampleRate
            let targetCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio + 1000)
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetProcessingFormat, frameCapacity: targetCapacity) else {
                throw SynthesisError.synthesisFailed("Failed to allocate converted buffer")
            }
            var error: NSError?
            var hasProvidedData = false
            converter.convert(to: converted, error: &error) { _, outStatus in
                if hasProvidedData {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                hasProvidedData = true
                outStatus.pointee = .haveData
                return sourceBuffer
            }
            if let err = error {
                throw err
            }
            finalBuffer = converted
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let outputFile = try AVAudioFile(
            forWriting: destinationURL,
            settings: outputSettings
        )
        try outputFile.write(from: finalBuffer)
    }
}

// MARK: - Network Session Factory & Test Protocol

public enum NetworkSessionFactory {
    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.protocolClasses = [TestURLProtocol.self] + (config.protocolClasses ?? [])
        return URLSession(configuration: config)
    }
}

public final class TestURLProtocol: URLProtocol, @unchecked Sendable {
    public static var testHandlers: [String: @Sendable (URLRequest) -> (HTTPURLResponse, Data)?] = [:]
    private static let lock = NSLock()

    public static func registerHandler(for prefix: String, handler: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data)?) {
        lock.lock()
        defer { lock.unlock() }
        testHandlers[prefix] = handler
    }

    public static func reset() {
        lock.lock()
        defer { lock.unlock() }
        testHandlers.removeAll()
    }

    override public class func canInit(with request: URLRequest) -> Bool {
        guard let urlStr = request.url?.absoluteString else { return false }
        lock.lock()
        defer { lock.unlock() }
        return testHandlers.keys.contains { urlStr.contains($0) }
    }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    private static func extractBodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }

    override public func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let urlStr = url.absoluteString

        TestURLProtocol.lock.lock()
        let matchingHandler = TestURLProtocol.testHandlers.first { urlStr.contains($0.key) }?.value
        TestURLProtocol.lock.unlock()

        var req = request
        if req.httpBody == nil, let bodyData = Self.extractBodyData(from: request) {
            req.httpBody = bodyData
        }

        if let handler = matchingHandler, let (resp, data) = handler(req) {
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override public func stopLoading() {}
}

// MARK: - Local PocketTTS Provider

public final class PocketTTSProvider: VoiceSynthesisProvider, @unchecked Sendable {
    public let providerType: SynthesisProviderType = .pocketTTS
    private let coordinator: LocalModelCoordinator
    private let ttsManager: PocketTtsManager
    private var cachedClonedVoices: [URL: PocketTtsVoiceData] = [:]
    public private(set) var cloneCount: Int = 0
    private let lock = NSLock()

    // Test hooks for deterministic verification without network/model downloads
    public var cloneVoiceHandler: (@Sendable (URL) async throws -> PocketTtsVoiceData)?
    public var synthesizeHandler: (@Sendable (String, PocketTtsVoiceData?) async throws -> Data)?

    public init(
        coordinator: LocalModelCoordinator = .shared,
        ttsManager: PocketTtsManager? = nil
    ) {
        self.coordinator = coordinator
        let mgr = ttsManager ?? PocketTtsManager()
        self.ttsManager = mgr

        Task { [weak mgr] in
            await coordinator.registerTeardown(for: .tts) {
                guard let mgr = mgr else { return }
                await mgr.cleanup()
            }
        }
    }

    public func invalidateVoiceCache(for url: URL? = nil) {
        lock.withLock {
            if let specificURL = url {
                cachedClonedVoices.removeValue(forKey: specificURL)
            } else {
                cachedClonedVoices.removeAll()
            }
        }
    }

    public func getClonedVoiceData(for audioURL: URL) async throws -> PocketTtsVoiceData {
        let cached = lock.withLock { cachedClonedVoices[audioURL] }
        if let cached = cached {
            return cached
        }

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw SynthesisError.invalidReferenceAudio
        }

        let voiceData: PocketTtsVoiceData
        if let handler = cloneVoiceHandler {
            voiceData = try await handler(audioURL)
        } else {
            let isAvail = await self.ttsManager.isAvailable
            if !isAvail {
                try await self.ttsManager.initialize()
            }
            voiceData = try await self.ttsManager.cloneVoice(from: audioURL)
        }
        lock.withLock {
            cachedClonedVoices[audioURL] = voiceData
            cloneCount += 1
        }
        return voiceData
    }

    public func synthesize(
        text: String,
        voiceID: String? = nil,
        referenceAudioURL: URL? = nil
    ) async throws -> AVAudioPCMBuffer {
        return try await coordinator.withExclusiveModel(.tts) {
            do {
                if self.cloneVoiceHandler == nil && self.synthesizeHandler == nil {
                    let isAvail = await self.ttsManager.isAvailable
                    if !isAvail {
                        try await self.ttsManager.initialize()
                    }
                }

                let wavData: Data
                if let refURL = referenceAudioURL {
                    guard FileManager.default.fileExists(atPath: refURL.path) else {
                        throw SynthesisError.invalidReferenceAudio
                    }
                    let cached = self.lock.withLock { self.cachedClonedVoices[refURL] }

                    let voiceData: PocketTtsVoiceData
                    if let cached = cached {
                        voiceData = cached
                    } else {
                        if let handler = self.cloneVoiceHandler {
                            voiceData = try await handler(refURL)
                        } else {
                            voiceData = try await self.ttsManager.cloneVoice(from: refURL)
                        }
                        self.lock.withLock {
                            self.cachedClonedVoices[refURL] = voiceData
                            self.cloneCount += 1
                        }
                    }
                    if let synthHandler = self.synthesizeHandler {
                        wavData = try await synthHandler(text, voiceData)
                    } else {
                        wavData = try await self.ttsManager.synthesize(text: text, voiceData: voiceData)
                    }
                } else {
                    if let synthHandler = self.synthesizeHandler {
                        wavData = try await synthHandler(text, nil)
                    } else {
                        wavData = try await self.ttsManager.synthesize(text: text, voice: voiceID)
                    }
                }

                return try AudioBufferUtils.pcmBuffer(fromAudioData: wavData, fileExtension: "wav")
            } catch let error as SynthesisError {
                throw error
            } catch {
                throw SynthesisError.synthesisFailed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Cloud Providers

public enum ElevenLabsModelConstants {
    public static let defaultModel = "eleven_multilingual_v2"
}

public final class ElevenLabsProvider: VoiceSynthesisProvider, @unchecked Sendable {
    public let providerType: SynthesisProviderType = .elevenLabs
    public let model: String
    private let vault: CredentialVaultProtocol
    private let session: URLSession

    public init(
        model: String = ElevenLabsModelConstants.defaultModel,
        vault: CredentialVaultProtocol = KeychainVault(),
        session: URLSession? = nil
    ) {
        self.model = model
        self.vault = vault
        self.session = session ?? NetworkSessionFactory.makeSession()
    }

    public func cloneVoice(name: String, audioURL: URL) async throws -> String {
        guard let apiKey = try vault.get(keyFor: .elevenLabs), !apiKey.isEmpty else {
            throw SynthesisError.missingAPIKey(.elevenLabs)
        }
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw SynthesisError.invalidReferenceAudio
        }
        return try await cloneVoiceNetwork(name: name, audioURL: audioURL, apiKey: apiKey)
    }

    public func synthesize(
        text: String,
        voiceID: String?,
        referenceAudioURL: URL? = nil
    ) async throws -> AVAudioPCMBuffer {
        guard let apiKey = try vault.get(keyFor: .elevenLabs), !apiKey.isEmpty else {
            throw SynthesisError.missingAPIKey(.elevenLabs)
        }

        var selectedVoiceID = voiceID
        if selectedVoiceID == nil || selectedVoiceID?.isEmpty == true {
            if let refURL = referenceAudioURL {
                guard FileManager.default.fileExists(atPath: refURL.path) else {
                    throw SynthesisError.invalidReferenceAudio
                }
                selectedVoiceID = try await cloneVoice(name: "macdub_clone", audioURL: refURL)
            } else {
                throw SynthesisError.synthesisFailed("ElevenLabs requires a configured voice ID or reference voice.")
            }
        }

        guard let validVoiceID = selectedVoiceID, !validVoiceID.isEmpty else {
            throw SynthesisError.synthesisFailed("Invalid or missing ElevenLabs voice ID")
        }

        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(validVoiceID)?output_format=mp3_44100_128") else {
            throw SynthesisError.synthesisFailed("Invalid ElevenLabs endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let payload: [String: Any] = [
            "text": text,
            "model_id": model,
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SynthesisError.synthesisFailed("Invalid HTTP response from ElevenLabs")
        }

        guard http.statusCode == 200 else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw SynthesisError.synthesisFailed("ElevenLabs error (HTTP \(http.statusCode)): \(errorMsg)")
        }

        return try AudioBufferUtils.pcmBuffer(fromAudioData: data, fileExtension: "mp3")
    }

    private func cloneVoiceNetwork(name: String, audioURL: URL, apiKey: String) async throws -> String {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/voices/add") else {
            throw SynthesisError.synthesisFailed("Invalid voice clone URL")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"name\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(name)\r\n".data(using: .utf8)!)

        let audioData = try Data(contentsOf: audioURL)
        let filename = audioURL.lastPathComponent
        let ext = audioURL.pathExtension.lowercased()
        let mimeType: String
        switch ext {
        case "wav": mimeType = "audio/wav"
        case "mp3": mimeType = "audio/mpeg"
        case "m4a", "mp4", "aac": mimeType = "audio/mp4"
        default: mimeType = "audio/wav"
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"files\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Voice clone failed"
            throw SynthesisError.synthesisFailed("ElevenLabs clone failed: \(errorMsg)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let voiceId = json["voice_id"] as? String else {
            throw SynthesisError.synthesisFailed("Could not parse cloned voice_id from response")
        }

        return voiceId
    }
}

public final class ResembleProvider: VoiceSynthesisProvider, @unchecked Sendable {
    public let providerType: SynthesisProviderType = .resemble
    private let vault: CredentialVaultProtocol
    private let session: URLSession

    public init(
        vault: CredentialVaultProtocol = KeychainVault(),
        session: URLSession? = nil
    ) {
        self.vault = vault
        self.session = session ?? NetworkSessionFactory.makeSession()
    }

    public func synthesize(
        text: String,
        voiceID: String?,
        referenceAudioURL: URL? = nil
    ) async throws -> AVAudioPCMBuffer {
        guard let apiKey = try vault.get(keyFor: .resemble), !apiKey.isEmpty else {
            throw SynthesisError.missingAPIKey(.resemble)
        }

        guard let voiceUUID = voiceID, !voiceUUID.isEmpty else {
            throw SynthesisError.synthesisFailed("Resemble requires a voice_uuid configured in Reference Voice or Provider Settings.")
        }

        guard let url = URL(string: "https://f.cluster.resemble.ai/synthesize") else {
            throw SynthesisError.synthesisFailed("Invalid Resemble API URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "voice_uuid": voiceUUID,
            "data": text
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SynthesisError.synthesisFailed("Invalid HTTP response from Resemble")
        }

        guard http.statusCode == 200 else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw SynthesisError.synthesisFailed("Resemble error (HTTP \(http.statusCode)): \(errorMsg)")
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let audioSrc = json["audio_src"] as? String, let audioURL = URL(string: audioSrc) {
                let (remoteAudio, _) = try await session.data(from: audioURL)
                return try AudioBufferUtils.pcmBuffer(fromAudioData: remoteAudio, fileExtension: "wav")
            } else if let audioBase64 = json["audio_content"] as? String, let decoded = Data(base64Encoded: audioBase64) {
                return try AudioBufferUtils.pcmBuffer(fromAudioData: decoded, fileExtension: "wav")
            } else if let item = json["item"] as? [String: Any], let audioSrc = item["audio_src"] as? String, let audioURL = URL(string: audioSrc) {
                let (remoteAudio, _) = try await session.data(from: audioURL)
                return try AudioBufferUtils.pcmBuffer(fromAudioData: remoteAudio, fileExtension: "wav")
            }
        }

        return try AudioBufferUtils.pcmBuffer(fromAudioData: data, fileExtension: "wav")
    }
}

public final class GeminiTTSProvider: VoiceSynthesisProvider, @unchecked Sendable {
    public let providerType: SynthesisProviderType = .geminiTTS
    public let model: String
    private let vault: CredentialVaultProtocol
    private let session: URLSession

    public init(
        model: String = GeminiModelConstants.defaultTTSModel,
        vault: CredentialVaultProtocol = KeychainVault(),
        session: URLSession? = nil
    ) {
        self.model = model
        self.vault = vault
        self.session = session ?? NetworkSessionFactory.makeSession()
    }

    public func synthesize(
        text: String,
        voiceID: String?,
        referenceAudioURL: URL? = nil
    ) async throws -> AVAudioPCMBuffer {
        // Strict architectural invariant: Gemini TTS is prebuilt natural voice only, reject voice cloning reference audio
        if referenceAudioURL != nil {
            throw SynthesisError.unsupportedOperation("Gemini TTS is a prebuilt natural voice provider and does not support voice cloning.")
        }
        guard let apiKey = try vault.get(keyFor: .gemini), !apiKey.isEmpty else {
            throw SynthesisError.missingAPIKey(.gemini)
        }

        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions") else {
            throw SynthesisError.synthesisFailed("Invalid Gemini API URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let voiceName = voiceID ?? "Puck"
        let payload: [String: Any] = [
            "model": model,
            "input": text,
            "response_format": [
                "type": "audio"
            ],
            "generation_config": [
                "speech_config": [
                    ["voice": voiceName]
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SynthesisError.synthesisFailed("Invalid HTTP response from Gemini TTS")
        }

        guard http.statusCode == 200 else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw SynthesisError.synthesisFailed("Gemini TTS error (HTTP \(http.statusCode)): \(errorMsg)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SynthesisError.synthesisFailed("Failed to parse JSON from Gemini TTS response")
        }

        var audioBase64: String? = nil
        var mimeType = "audio/wav"

        if let outAudio = json["output_audio"] as? [String: Any] {
            audioBase64 = outAudio["data"] as? String
            mimeType = (outAudio["mime_type"] as? String) ?? (outAudio["mimeType"] as? String) ?? "audio/wav"
        } else if let interaction = json["interaction"] as? [String: Any],
                  let outAudio = interaction["output_audio"] as? [String: Any] {
            audioBase64 = outAudio["data"] as? String
            mimeType = (outAudio["mime_type"] as? String) ?? (outAudio["mimeType"] as? String) ?? "audio/wav"
        } else if let steps = json["steps"] as? [[String: Any]] {
            for step in steps {
                if let modelOutput = step["model_output"] as? [String: Any],
                   let audio = modelOutput["audio"] as? [String: Any] {
                    audioBase64 = audio["data"] as? String
                    mimeType = (audio["mime_type"] as? String) ?? (audio["mimeType"] as? String) ?? "audio/wav"
                    break
                }
            }
        } else if let candidates = json["candidates"] as? [[String: Any]] {
            for candidate in candidates {
                if let content = candidate["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]] {
                    for part in parts {
                        if let inlineData = (part["inlineData"] as? [String: Any]) ?? (part["inline_data"] as? [String: Any]) {
                            audioBase64 = inlineData["data"] as? String
                            mimeType = (inlineData["mimeType"] as? String) ?? (inlineData["mime_type"] as? String) ?? "audio/wav"
                            break
                        }
                    }
                }
                if audioBase64 != nil { break }
            }
        }

        guard let base64Str = audioBase64, let audioData = Data(base64Encoded: base64Str) else {
            throw SynthesisError.synthesisFailed("Failed to parse audio data from Gemini TTS response")
        }

        let wavData: Data
        if mimeType.contains("wav") || audioData.starts(with: "RIFF".utf8) {
            wavData = audioData
        } else {
            wavData = AudioBufferUtils.wrapPCM16InWAV(pcmData: audioData, sampleRate: 24000, channels: 1)
        }

        return try AudioBufferUtils.pcmBuffer(fromAudioData: wavData, fileExtension: "wav")
    }
}

// MARK: - Persistent Synthesis Provider Registry

public final class SynthesisProviderRegistry: @unchecked Sendable {
    public let pocketTTS: PocketTTSProvider
    public let elevenLabs: ElevenLabsProvider
    public let resemble: ResembleProvider
    public let geminiTTS: GeminiTTSProvider

    public init(
        pocketTTS: PocketTTSProvider = PocketTTSProvider(),
        elevenLabs: ElevenLabsProvider = ElevenLabsProvider(),
        resemble: ResembleProvider = ResembleProvider(),
        geminiTTS: GeminiTTSProvider = GeminiTTSProvider()
    ) {
        self.pocketTTS = pocketTTS
        self.elevenLabs = elevenLabs
        self.resemble = resemble
        self.geminiTTS = geminiTTS
    }

    public func provider(for type: SynthesisProviderType) -> VoiceSynthesisProvider {
        switch type {
        case .pocketTTS: return pocketTTS
        case .elevenLabs: return elevenLabs
        case .resemble: return resemble
        case .geminiTTS: return geminiTTS
        }
    }
}
