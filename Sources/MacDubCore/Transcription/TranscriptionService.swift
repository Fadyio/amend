import Foundation
import CoreMedia
import AVFoundation
import FluidAudio

public struct WordTiming: Sendable, Equatable, Codable {
    public let word: String
    public let timeRange: CMTimeRange
    public let confidence: Float

    public init(word: String, timeRange: CMTimeRange, confidence: Float = 1.0) {
        self.word = word
        self.timeRange = timeRange
        self.confidence = confidence
    }

    public var start: CMTime { timeRange.start }
    public var duration: CMTime { timeRange.duration }
    public var end: CMTime { timeRange.end }
}

public protocol TranscriptionServing: Sendable {
    func transcribe(audioBuffer: AVAudioPCMBuffer) async throws -> [WordTiming]
    func transcribe(audioURL: URL) async throws -> [WordTiming]
}

public enum TranscriptionError: Error, LocalizedError {
    case invalidAudioBuffer
    case modelUnavailable
    case transcriptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAudioBuffer:
            return "Invalid or unreadable audio buffer for transcription"
        case .modelUnavailable:
            return "Local ASR model is unavailable or not loaded"
        case .transcriptionFailed(let msg):
            return "Transcription failed: \(msg)"
        }
    }
}

public final class TranscriptionService: TranscriptionServing, @unchecked Sendable {
    private let coordinator: LocalModelCoordinator

    public init(coordinator: LocalModelCoordinator = .shared) {
        self.coordinator = coordinator
    }

    public func transcribe(audioBuffer: AVAudioPCMBuffer) async throws -> [WordTiming] {
        guard audioBuffer.frameLength > 0 else {
            return []
        }

        return try await coordinator.withExclusiveModel(.asr) {
            let asrManager = AsrManager()
            let result = try await asrManager.transcribe(audioBuffer, source: .system)
            await asrManager.cleanup()

            guard let tokenTimings = result.tokenTimings, !tokenTimings.isEmpty else {
                let duration = CMTime(seconds: result.duration, preferredTimescale: 600_000)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return [] }
                return [WordTiming(word: text, timeRange: CMTimeRange(start: .zero, duration: duration), confidence: result.confidence)]
            }

            return self.aggregateTokensToWords(tokenTimings)
        }
    }

    public func transcribe(audioURL: URL) async throws -> [WordTiming] {
        let file = try AVAudioFile(forReading: audioURL)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw TranscriptionError.invalidAudioBuffer
        }
        try file.read(into: buffer)
        return try await transcribe(audioBuffer: buffer)
    }

    internal func aggregateTokensToWords(_ tokens: [TokenTiming]) -> [WordTiming] {
        var words: [WordTiming] = []
        var currentWord = ""
        var wordStart: TimeInterval?
        var wordEnd: TimeInterval = 0
        var confidences: [Float] = []

        for t in tokens {
            let tokenText = t.token
            // In sentencepiece/BPE, leading space often indicates word boundary (' ' or space)
            let isNewWord = tokenText.hasPrefix(" ") || tokenText.hasPrefix(" ") || currentWord.isEmpty

            if isNewWord && !currentWord.isEmpty {
                if let start = wordStart {
                    let duration = max(0.01, wordEnd - start)
                    let avgConf = confidences.isEmpty ? 1.0 : (confidences.reduce(0, +) / Float(confidences.count))
                    words.append(WordTiming(
                        word: currentWord.trimmingCharacters(in: .whitespaces),
                        timeRange: CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600_000), duration: CMTime(seconds: duration, preferredTimescale: 600_000)),
                        confidence: avgConf
                    ))
                }
                currentWord = ""
                wordStart = nil
                confidences.removeAll()
            }

            if wordStart == nil {
                wordStart = t.startTime
            }
            wordEnd = max(wordEnd, t.endTime)
            currentWord += tokenText.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: " ", with: "")
            confidences.append(t.confidence)
        }

        if !currentWord.isEmpty, let start = wordStart {
            let duration = max(0.01, wordEnd - start)
            let avgConf = confidences.isEmpty ? 1.0 : (confidences.reduce(0, +) / Float(confidences.count))
            words.append(WordTiming(
                word: currentWord.trimmingCharacters(in: .whitespaces),
                timeRange: CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600_000), duration: CMTime(seconds: duration, preferredTimescale: 600_000)),
                confidence: avgConf
            ))
        }

        return words
    }
}

/// Deterministic mock transcription service for unit testing without Core ML model downloads.
public final class MockTranscriptionService: TranscriptionServing, @unchecked Sendable {
    public var scriptedTimings: [WordTiming]
    public var lastTranscribedBuffer: AVAudioPCMBuffer?

    public init(scriptedTimings: [WordTiming] = []) {
        self.scriptedTimings = scriptedTimings
    }

    public func transcribe(audioBuffer: AVAudioPCMBuffer) async throws -> [WordTiming] {
        self.lastTranscribedBuffer = audioBuffer
        return scriptedTimings
    }

    public func transcribe(audioURL: URL) async throws -> [WordTiming] {
        return scriptedTimings
    }
}
