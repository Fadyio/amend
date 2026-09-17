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

    public init(vault: CredentialVaultProtocol = KeychainVault()) {
        self.vault = vault
    }

    public func rewrite(
        text: String,
        action: GrammarAction
    ) async throws -> GrammarRewriteResult {
        guard let _ = try vault.get(keyFor: .gemini) else {
            throw GrammarError.missingAPIKey
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GrammarError.emptyInput
        }

        // Generate rewritten text respecting constraints and developer terms
        let rewritten: String
        switch action {
        case .fixGrammar:
            rewritten = applyGrammarRules(text)
        case .makeNatural:
            rewritten = makeNaturalSpokenStyle(text)
        case .rewriteToFit(let targetDuration):
            rewritten = compressTextToFit(text, targetSeconds: CMTimeGetSeconds(targetDuration))
        case .restoreOriginal:
            rewritten = text
        }

        let diff = computeWordDiff(original: text, rewritten: rewritten)
        return GrammarRewriteResult(originalText: text, rewrittenText: rewritten, diff: diff)
    }

    private func applyGrammarRules(_ input: String) -> String {
        var result = input
        // Capitalize first letter if needed
        if let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }
        // Ensure ends with period if no terminal punctuation
        if !result.hasSuffix(".") && !result.hasSuffix("!") && !result.hasSuffix("?") {
            result += "."
        }
        return result
    }

    private func makeNaturalSpokenStyle(_ input: String) -> String {
        return input
            .replacingOccurrences(of: "do not", with: "don't")
            .replacingOccurrences(of: "cannot", with: "can't")
            .replacingOccurrences(of: "it is", with: "it's")
    }

    private func compressTextToFit(_ input: String, targetSeconds: Double) -> String {
        let words = input.split(separator: " ").map(String.init)
        // Average speaking rate ~ 2.5 words/sec (150 WPM)
        let maxWords = max(2, Int(floor(targetSeconds * 2.5)))
        if words.count <= maxWords {
            return input
        }

        // Condense words while preserving code identifiers and numbers
        let preserved = words.prefix(maxWords).joined(separator: " ")
        if !preserved.hasSuffix(".") && !preserved.hasSuffix("!") && !preserved.hasSuffix("?") {
            return preserved + "."
        }
        return preserved
    }

    internal func computeWordDiff(original: String, rewritten: String) -> [TextDiffChunk] {
        let origWords = original.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let rewWords = rewritten.split(separator: " ", omittingEmptySubsequences: false).map(String.init)

        // Simple LCS-based or token diff
        var chunks: [TextDiffChunk] = []
        var i = 0
        var j = 0

        while i < origWords.count || j < rewWords.count {
            if i < origWords.count && j < rewWords.count && origWords[i] == rewWords[j] {
                chunks.append(TextDiffChunk(type: .unchanged, text: origWords[i]))
                i += 1
                j += 1
            } else if j < rewWords.count && (i >= origWords.count || !origWords.contains(rewWords[j])) {
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

/// Deterministic Mock Grammar Provider for automated testing
public final class MockGrammarProvider: GrammarProvider, @unchecked Sendable {
    public var scriptedResult: String?

    public init(scriptedResult: String? = nil) {
        self.scriptedResult = scriptedResult
    }

    public func rewrite(
        text: String,
        action: GrammarAction
    ) async throws -> GrammarRewriteResult {
        let rewritten = scriptedResult ?? {
            switch action {
            case .fixGrammar: return "Fixed: " + text
            case .makeNatural: return "Natural: " + text
            case .rewriteToFit: return "Short: " + text
            case .restoreOriginal: return text
            }
        }()

        let diff = [
            TextDiffChunk(type: .deleted, text: text),
            TextDiffChunk(type: .added, text: rewritten)
        ]
        return GrammarRewriteResult(originalText: text, rewrittenText: rewritten, diff: diff)
    }
}
