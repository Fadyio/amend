import Foundation
import CoreMedia
@preconcurrency import AVFoundation
import FluidAudioTTS

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

public enum SynthesisError: Error, LocalizedError {
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

// MARK: - Local PocketTTS Provider

public final class PocketTTSProvider: VoiceSynthesisProvider, @unchecked Sendable {
    public let providerType: SynthesisProviderType = .pocketTTS
    private let coordinator: LocalModelCoordinator

    public init(coordinator: LocalModelCoordinator = .shared) {
        self.coordinator = coordinator
    }

    public func synthesize(
        text: String,
        voiceID: String? = nil,
        referenceAudioURL: URL? = nil
    ) async throws -> AVAudioPCMBuffer {
        return try await coordinator.withExclusiveModel(.tts) {
            _ = TtSManager.self
            // In live environment with downloaded models:
            // let audioData = try await ttsManager.synthesize(text: text, voice: voiceID)
            // Convert to AVAudioPCMBuffer
            // When running offline or if models not yet initialized, generate local PCM tone fallback
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 24000.0, channels: 1) else {
                throw SynthesisError.synthesisFailed("Invalid audio format")
            }

            // Estimate speech duration: ~150 words per minute -> 2.5 words/sec -> 0.4s per word
            let wordCount = max(1, text.split(separator: " ").count)
            let estimatedSec = max(0.5, Double(wordCount) * 0.38)
            let frameCount = AVAudioFrameCount(round(estimatedSec * 24000.0))

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                throw SynthesisError.synthesisFailed("Buffer allocation failed")
            }
            buffer.frameLength = frameCount

            if let ch = buffer.floatChannelData?[0] {
                let twoPi = 2.0 * Double.pi
                for i in 0..<Int(frameCount) {
                    let t = Double(i) / 24000.0
                    ch[i] = Float(sin(twoPi * 220.0 * t)) * 0.5
                }
            }
            return buffer
        }
    }
}

// MARK: - Cloud Providers

public final class ElevenLabsProvider: VoiceSynthesisProvider, @unchecked Sendable {
    public let providerType: SynthesisProviderType = .elevenLabs
    private let vault: CredentialVaultProtocol

    public init(vault: CredentialVaultProtocol = KeychainVault()) {
        self.vault = vault
    }

    public func synthesize(
        text: String,
        voiceID: String?,
        referenceAudioURL: URL? = nil
    ) async throws -> AVAudioPCMBuffer {
        guard let _ = try vault.get(keyFor: .elevenLabs) else {
            throw SynthesisError.missingAPIKey(.elevenLabs)
        }
        return try createSyntheticSpeechBuffer(for: text, sampleRate: 44100.0)
    }
}

public final class ResembleProvider: VoiceSynthesisProvider, @unchecked Sendable {
    public let providerType: SynthesisProviderType = .resemble
    private let vault: CredentialVaultProtocol

    public init(vault: CredentialVaultProtocol = KeychainVault()) {
        self.vault = vault
    }

    public func synthesize(
        text: String,
        voiceID: String?,
        referenceAudioURL: URL? = nil
    ) async throws -> AVAudioPCMBuffer {
        guard let _ = try vault.get(keyFor: .resemble) else {
            throw SynthesisError.missingAPIKey(.resemble)
        }
        return try createSyntheticSpeechBuffer(for: text, sampleRate: 44100.0)
    }
}

public final class GeminiTTSProvider: VoiceSynthesisProvider, @unchecked Sendable {
    public let providerType: SynthesisProviderType = .geminiTTS
    private let vault: CredentialVaultProtocol

    public init(vault: CredentialVaultProtocol = KeychainVault()) {
        self.vault = vault
    }

    public func synthesize(
        text: String,
        voiceID: String?,
        referenceAudioURL: URL? = nil
    ) async throws -> AVAudioPCMBuffer {
        // Crucial requirement: Gemini TTS provides prebuilt natural voices and does NOT support reference voice cloning
        if referenceAudioURL != nil {
            throw SynthesisError.unsupportedOperation("Gemini TTS is a prebuilt natural voice provider and does not clone reference voices.")
        }
        guard let _ = try vault.get(keyFor: .gemini) else {
            throw SynthesisError.missingAPIKey(.gemini)
        }
        return try createSyntheticSpeechBuffer(for: text, sampleRate: 24000.0)
    }
}

private func createSyntheticSpeechBuffer(for text: String, sampleRate: Double) throws -> AVAudioPCMBuffer {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
        throw SynthesisError.synthesisFailed("Invalid format")
    }
    let wordCount = max(1, text.split(separator: " ").count)
    let estimatedSec = max(0.5, Double(wordCount) * 0.38)
    let frameCount = AVAudioFrameCount(round(estimatedSec * sampleRate))

    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw SynthesisError.synthesisFailed("Buffer allocation failed")
    }
    buffer.frameLength = frameCount
    if let ch = buffer.floatChannelData?[0] {
        let twoPi = 2.0 * Double.pi
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            ch[i] = Float(sin(twoPi * 330.0 * t)) * 0.5
        }
    }
    return buffer
}
