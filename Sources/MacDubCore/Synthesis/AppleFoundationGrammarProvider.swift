import Foundation
import CoreMedia
#if canImport(FoundationModels)
import FoundationModels
#endif

public enum AppleIntelligenceAvailability: Equatable, Sendable {
    case available
    case modelDownloading
    case notEnabled
    case deviceNotEligible
    case unavailable(String)

    public var isAvailable: Bool {
        self == .available
    }

    public var description: String {
        switch self {
        case .available:
            return "Apple Intelligence — Available"
        case .modelDownloading:
            return "Apple Intelligence — Model downloading"
        case .notEnabled:
            return "Apple Intelligence — Disabled in Settings"
        case .deviceNotEligible:
            return "Apple Intelligence — Device Not Eligible"
        case .unavailable(let reason):
            return "Apple Intelligence — Unavailable (\(reason))"
        }
    }

    public static func currentAvailability() -> AppleIntelligenceAvailability {
        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .modelNotReady:
                return .modelDownloading
            case .appleIntelligenceNotEnabled:
                return .notEnabled
            case .deviceNotEligible:
                return .deviceNotEligible
            @unknown default:
                return .unavailable("Unknown system state")
            }
        }
        #else
        return .unavailable("FoundationModels framework not present in host SDK")
        #endif
    }
}

public struct StructuredRewriteOutput: Equatable, Sendable {
    public let rewrittenText: String
    public let changeSummary: String
    public let estimatedWordCount: Int

    public init(rewrittenText: String, changeSummary: String, estimatedWordCount: Int) {
        self.rewrittenText = rewrittenText
        self.changeSummary = changeSummary
        self.estimatedWordCount = estimatedWordCount
    }
}

public protocol FoundationLanguageModelSessionProtocol: Sendable {
    func rewrite(prompt: String, action: GrammarAction) async throws -> StructuredRewriteOutput
}

public final class SystemFoundationLanguageModelSession: FoundationLanguageModelSessionProtocol, @unchecked Sendable {
    public init() {}

    public func rewrite(prompt: String, action: GrammarAction) async throws -> StructuredRewriteOutput {
        #if canImport(FoundationModels)
        let instructions = makeInstructions(for: action)
        let session = LanguageModelSession(instructions: instructions)

        let rootSchema = DynamicGenerationSchema(
            name: "RewriteResponse",
            description: "Structured rewritten narration result",
            properties: [
                DynamicGenerationSchema.Property(
                    name: "rewrittenText",
                    description: "The rewritten narration text",
                    schema: DynamicGenerationSchema(type: String.self)
                ),
                DynamicGenerationSchema.Property(
                    name: "changeSummary",
                    description: "Brief summary of changes made",
                    schema: DynamicGenerationSchema(type: String.self)
                ),
                DynamicGenerationSchema.Property(
                    name: "estimatedWordCount",
                    description: "Estimated word count of the rewritten text",
                    schema: DynamicGenerationSchema(type: Int.self)
                )
            ]
        )

        let schema = try GenerationSchema(root: rootSchema, dependencies: [])
        let response = try await session.respond(to: prompt, schema: schema)

        var text = (try? response.content.value(String.self, forProperty: "rewrittenText")) ?? ""
        let summary = (try? response.content.value(String.self, forProperty: "changeSummary")) ?? ""
        var count = (try? response.content.value(Int.self, forProperty: "estimatedWordCount")) ?? 0

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\"") && text.hasSuffix("\"") && text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        guard !text.isEmpty else {
            throw GrammarError.rewriteFailed("Apple Foundation Models returned an empty response")
        }
        if count == 0 {
            count = text.split(separator: " ").count
        }

        return StructuredRewriteOutput(rewrittenText: text, changeSummary: summary, estimatedWordCount: count)
        #else
        throw GrammarError.providerUnavailable("FoundationModels framework not available in host SDK")
        #endif
    }

    private func makeInstructions(for action: GrammarAction) -> String {
        switch action {
        case .fixGrammar:
            return """
            You are a professional audio transcript editor. Fix grammar, spelling, punctuation, capitalization, sentence structure, and obvious speech recognition errors in the narration.
            Strictly preserve technical vocabulary, filenames, code identifiers, product names, URLs, shell commands, and API names without alteration.
            """

        case .makeNatural:
            return """
            You are a professional audio transcript editor. Turn rough spoken hackathon or demo narration into clear, natural, conversational spoken voiceover without altering original meaning.
            Strictly preserve all technical terminology, framework names, product names, and code identifiers.
            """

        case .rewriteToFit(let targetDuration):
            let seconds = CMTimeGetSeconds(targetDuration)
            let maxWords = max(2, Int(floor(seconds * 2.5)))
            return """
            You are a professional voiceover script editor. Condense and rewrite the spoken transcript to comfortably fit within \(String(format: "%.2f", seconds)) seconds at standard conversational speaking rate (~150 words per minute, target maximum ~\(maxWords) words).
            Preserve essential technical terms, code identifiers, numbers, and core meaning. Do not invent product claims or truncate text mechanically.
            """

        case .restoreOriginal:
            return "Restore original narration."
        }
    }
}

public final class AppleFoundationGrammarProvider: GrammarProvider, @unchecked Sendable {
    private let sessionFactory: @Sendable () -> FoundationLanguageModelSessionProtocol
    private let availabilityCheck: @Sendable () -> AppleIntelligenceAvailability
    private let coordinator: LocalModelCoordinator

    public var availability: AppleIntelligenceAvailability {
        availabilityCheck()
    }

    public var isAvailable: Bool {
        availabilityCheck().isAvailable
    }

    public init(
        sessionFactory: @escaping @Sendable () -> FoundationLanguageModelSessionProtocol = { SystemFoundationLanguageModelSession() },
        availabilityCheck: @escaping @Sendable () -> AppleIntelligenceAvailability = { AppleIntelligenceAvailability.currentAvailability() },
        coordinator: LocalModelCoordinator = .shared
    ) {
        self.sessionFactory = sessionFactory
        self.availabilityCheck = availabilityCheck
        self.coordinator = coordinator
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
            return GrammarRewriteResult(
                originalText: text,
                rewrittenText: text,
                diff: [TextDiffChunk(type: .unchanged, text: text)]
            )
        }

        let avail = availabilityCheck()
        guard avail.isAvailable else {
            throw GrammarError.providerUnavailable(avail.description)
        }

        let session = sessionFactory()

        let structuredOutput: StructuredRewriteOutput = try await coordinator.withExclusiveModel(.llm) {
            do {
                return try await session.rewrite(prompt: trimmed, action: action)
            } catch {
                throw GrammarError.rewriteFailed("Apple Foundation Models inference failed: \(error.localizedDescription)")
            }
        }

        let cleanRewritten = structuredOutput.rewrittenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanRewritten.isEmpty else {
            throw GrammarError.rewriteFailed("Apple Foundation Models returned an empty response")
        }

        let diff = WordDiffUtility.computeWordDiff(original: text, rewritten: cleanRewritten)
        return GrammarRewriteResult(
            originalText: text,
            rewrittenText: cleanRewritten,
            diff: diff
        )
    }
}

public final class AdaptiveGrammarProvider: GrammarProvider, @unchecked Sendable {
    public let localProvider: AppleFoundationGrammarProvider
    public let cloudProvider: GeminiGrammarProvider
    public let fallbackToCloud: Bool

    public init(
        localProvider: AppleFoundationGrammarProvider = AppleFoundationGrammarProvider(),
        cloudProvider: GeminiGrammarProvider = GeminiGrammarProvider(),
        fallbackToCloud: Bool = true
    ) {
        self.localProvider = localProvider
        self.cloudProvider = cloudProvider
        self.fallbackToCloud = fallbackToCloud
    }

    public func rewrite(
        text: String,
        action: GrammarAction
    ) async throws -> GrammarRewriteResult {
        if localProvider.isAvailable {
            do {
                return try await localProvider.rewrite(text: text, action: action)
            } catch {
                if fallbackToCloud {
                    return try await cloudProvider.rewrite(text: text, action: action)
                }
                throw error
            }
        } else {
            return try await cloudProvider.rewrite(text: text, action: action)
        }
    }
}
