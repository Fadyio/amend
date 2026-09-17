import Foundation
import CoreMedia

public enum GrammarAction: Equatable, Sendable {
    case fixGrammar
    case makeNatural
    case rewriteToFit(targetDuration: CMTime)
    case restoreOriginal

    public var title: String {
        switch self {
        case .fixGrammar: return "Fix Grammar"
        case .makeNatural: return "Make Natural"
        case .rewriteToFit: return "Rewrite to Fit"
        case .restoreOriginal: return "Restore Original"
        }
    }
}

public enum DiffChunkType: Equatable, Sendable {
    case unchanged
    case added
    case deleted
}

public struct TextDiffChunk: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public let type: DiffChunkType
    public let text: String

    public init(type: DiffChunkType, text: String) {
        self.type = type
        self.text = text
    }
}

public struct GrammarRewriteResult: Equatable, Sendable {
    public let originalText: String
    public let rewrittenText: String
    public let diff: [TextDiffChunk]

    public init(originalText: String, rewrittenText: String, diff: [TextDiffChunk]) {
        self.originalText = originalText
        self.rewrittenText = rewrittenText
        self.diff = diff
    }
}

public protocol GrammarProvider: Sendable {
    func rewrite(
        text: String,
        action: GrammarAction
    ) async throws -> GrammarRewriteResult
}

public enum GrammarError: Error, LocalizedError {
    case missingAPIKey
    case emptyInput
    case providerUnavailable(String)
    case rewriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Gemini API key not found in Keychain"
        case .emptyInput:
            return "Cannot rewrite empty transcript text"
        case .providerUnavailable(let msg):
            return "Grammar provider unavailable: \(msg)"
        case .rewriteFailed(let msg):
            return "Grammar rewrite failed: \(msg)"
        }
    }
}

public final class GeminiGrammarProvider: GrammarProvider, @unchecked Sendable {
    private let vault: CredentialVaultProtocol
    private let session: URLSession

    public init(
        vault: CredentialVaultProtocol = KeychainVault(),
        session: URLSession? = nil
    ) {
        self.vault = vault
        self.session = session ?? NetworkSessionFactory.makeSession()
    }

    public func rewrite(
        text: String,
        action: GrammarAction
    ) async throws -> GrammarRewriteResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GrammarError.emptyInput
        }

        if case .restoreOriginal = action {
            return GrammarRewriteResult(originalText: text, rewrittenText: text, diff: [TextDiffChunk(type: .unchanged, text: text)])
        }

        guard let apiKey = try vault.get(keyFor: .gemini), !apiKey.isEmpty else {
            throw GrammarError.missingAPIKey
        }

        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=\(apiKey)") else {
            throw GrammarError.providerUnavailable("Invalid Generative Language API endpoint URL")
        }

        let prompt = makePrompt(for: trimmed, action: action)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let actionHeader: String
        switch action {
        case .fixGrammar: actionHeader = "fixGrammar"
        case .makeNatural: actionHeader = "makeNatural"
        case .rewriteToFit: actionHeader = "rewriteToFit"
        case .restoreOriginal: actionHeader = "restoreOriginal"
        }
        request.setValue(actionHeader, forHTTPHeaderField: "X-MacDub-Action")

        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.2,
                "maxOutputTokens": 2048
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GrammarError.providerUnavailable("Network error: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw GrammarError.providerUnavailable("Invalid HTTP response")
        }

        guard http.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw GrammarError.rewriteFailed("Gemini API error (HTTP \(http.statusCode)): \(errorBody)")
        }

        let rewritten = try parseGeminiResponse(data)
        let diff = computeWordDiff(original: text, rewritten: rewritten)
        return GrammarRewriteResult(originalText: text, rewrittenText: rewritten, diff: diff)
    }

    private func makePrompt(for text: String, action: GrammarAction) -> String {
        switch action {
        case .fixGrammar:
            return """
            You are a professional audio transcript editor. Fix grammar, spelling, punctuation, and capitalization in the following spoken transcription while keeping wording and technical identifiers as close to the original as possible. Output ONLY the corrected text, with no preamble, quotes, or explanation.

            Input:
            \(text)
            """

        case .makeNatural:
            return """
            You are a professional audio transcript editor. Rewrite the following spoken transcription to sound more natural, fluent, and conversational for spoken voice narration. Preserve all key technical terms, names, and original meaning. Output ONLY the natural spoken text, with no preamble, quotes, or explanation.

            Input:
            \(text)
            """

        case .rewriteToFit(let targetDuration):
            let seconds = CMTimeGetSeconds(targetDuration)
            let maxWords = max(2, Int(floor(seconds * 2.5)))
            return """
            You are a professional voiceover script editor. Condense and rewrite the following spoken transcript to fit within \(String(format: "%.2f", seconds)) seconds when spoken at standard 150 words per minute rate (maximum ~\(maxWords) words). Preserve essential technical terms, code identifiers, numbers, and core meaning. Output ONLY the condensed rewritten text, with no preamble, quotes, or explanation.

            Input:
            \(text)
            """

        case .restoreOriginal:
            return text
        }
    }

    private func parseGeminiResponse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            throw GrammarError.rewriteFailed("Invalid response JSON structure from Gemini API")
        }

        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") && cleaned.count >= 2 {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        return cleaned
    }

    internal func computeWordDiff(original: String, rewritten: String) -> [TextDiffChunk] {
        let origWords = original.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let rewWords = rewritten.split(separator: " ", omittingEmptySubsequences: false).map(String.init)

        var chunks: [TextDiffChunk] = []
        var i = 0
        var j = 0

        while i < origWords.count || j < rewWords.count {
            if i < origWords.count && j < rewWords.count && origWords[i] == rewWords[j] {
                chunks.append(TextDiffChunk(type: .unchanged, text: origWords[i]))
                i += 1
                j += 1
            } else if j < rewWords.count && (i >= origWords.count || !origWords[i...].contains(rewWords[j])) {
                chunks.append(TextDiffChunk(type: .added, text: rewWords[j]))
                j += 1
            } else if i < origWords.count {
                chunks.append(TextDiffChunk(type: .deleted, text: origWords[i]))
                i += 1
            }
        }

        return chunks
    }
}
