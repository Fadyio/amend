import Testing
import Foundation
import CoreMedia
import FoundationModels
@testable import MacDubCore

private final class MockFoundationSession: FoundationLanguageModelSessionProtocol, @unchecked Sendable {
    var scriptedOutput: StructuredRewriteOutput?
    var errorToThrow: Error?
    var lastPrompt: String?
    var lastAction: GrammarAction?

    init(scriptedOutput: StructuredRewriteOutput? = nil, errorToThrow: Error? = nil) {
        self.scriptedOutput = scriptedOutput
        self.errorToThrow = errorToThrow
    }

    func rewrite(prompt: String, action: GrammarAction) async throws -> StructuredRewriteOutput {
        self.lastPrompt = prompt
        self.lastAction = action
        if let error = errorToThrow {
            throw error
        }
        guard let output = scriptedOutput else {
            throw GrammarError.rewriteFailed("No scripted output provided in MockFoundationSession")
        }
        return output
    }
}

private final class MockCloudGrammarProvider: GrammarProvider, @unchecked Sendable {
    var callCount = 0
    var scriptedResult: GrammarRewriteResult?
    var errorToThrow: Error?

    init(scriptedResult: GrammarRewriteResult? = nil, errorToThrow: Error? = nil) {
        self.scriptedResult = scriptedResult
        self.errorToThrow = errorToThrow
    }

    func rewrite(text: String, action: GrammarAction) async throws -> GrammarRewriteResult {
        callCount += 1
        if let error = errorToThrow {
            throw error
        }
        return scriptedResult ?? GrammarRewriteResult(
            originalText: text,
            rewrittenText: "Cloud: " + text,
            diff: [TextDiffChunk(type: .unchanged, text: text)]
        )
    }
}

@Suite("Apple Foundation Grammar Provider Tests")
struct AppleFoundationGrammarTests {

    @Test("Successful rewrite with mock Foundation Models session computes structured diff")
    func test_mock_foundation_rewrite_success() async throws {
        let mockSession = MockFoundationSession(
            scriptedOutput: StructuredRewriteOutput(
                rewrittenText: "This function basically fetches all users.",
                changeSummary: "Fixed subject-verb agreement",
                estimatedWordCount: 6
            )
        )
        let provider = AppleFoundationGrammarProvider(
            sessionFactory: { mockSession },
            availabilityCheck: { .available }
        )

        let input = "this functions basically go and fetch all users"
        let result = try await provider.rewrite(text: input, action: .fixGrammar)

        #expect(result.originalText == input)
        #expect(result.rewrittenText == "This function basically fetches all users.")
        #expect(mockSession.lastPrompt == input)
        #expect(mockSession.lastAction == .fixGrammar)
        #expect(!result.diff.isEmpty)
    }

    @Test("Empty input throws emptyInput error without invoking session")
    func test_empty_input_throws() async {
        let mockSession = MockFoundationSession()
        let provider = AppleFoundationGrammarProvider(
            sessionFactory: { mockSession },
            availabilityCheck: { .available }
        )

        await #expect(throws: GrammarError.emptyInput) {
            try await provider.rewrite(text: "   \n\t  ", action: .fixGrammar)
        }
        #expect(mockSession.lastPrompt == nil)
    }

    @Test("Restore original action returns unchanged text immediately")
    func test_restore_original_returns_immediately() async throws {
        let mockSession = MockFoundationSession()
        let provider = AppleFoundationGrammarProvider(
            sessionFactory: { mockSession },
            availabilityCheck: { .available }
        )

        let input = "Keep this text exactly the same."
        let result = try await provider.rewrite(text: input, action: .restoreOriginal)

        #expect(result.originalText == input)
        #expect(result.rewrittenText == input)
        #expect(result.diff.count == 1)
        #expect(result.diff[0].type == .unchanged)
        #expect(mockSession.lastPrompt == nil)
    }

    @Test("Unavailable Apple Intelligence throws providerUnavailable error")
    func test_unavailable_throws_error() async {
        let mockSession = MockFoundationSession()
        let provider = AppleFoundationGrammarProvider(
            sessionFactory: { mockSession },
            availabilityCheck: { .notEnabled }
        )

        await #expect(throws: GrammarError.self) {
            try await provider.rewrite(text: "Hello world", action: .makeNatural)
        }
    }

    @Test("Model downloading status reports correct availability state")
    func test_model_downloading_availability() {
        let provider = AppleFoundationGrammarProvider(
            availabilityCheck: { .modelDownloading }
        )
        #expect(!provider.isAvailable)
        #expect(provider.availability == .modelDownloading)
        #expect(provider.availability.description.contains("downloading"))
    }

    @Test("Session inference failure is wrapped in GrammarError.rewriteFailed")
    func test_inference_failure_wrapped() async {
        struct TestInferenceError: Error, LocalizedError {
            var errorDescription: String? { "Out of context window memory" }
        }
        let mockSession = MockFoundationSession(errorToThrow: TestInferenceError())
        let provider = AppleFoundationGrammarProvider(
            sessionFactory: { mockSession },
            availabilityCheck: { .available }
        )

        await #expect(throws: GrammarError.self) {
            try await provider.rewrite(text: "Sample transcript sentence", action: .fixGrammar)
        }
    }

    @Test("Adaptive provider uses local Apple Foundation Models when available")
    func test_adaptive_provider_prefers_local() async throws {
        let mockSession = MockFoundationSession(
            scriptedOutput: StructuredRewriteOutput(
                rewrittenText: "Local rewrite result",
                changeSummary: "Polished",
                estimatedWordCount: 3
            )
        )
        let localProvider = AppleFoundationGrammarProvider(
            sessionFactory: { mockSession },
            availabilityCheck: { .available }
        )
        let cloudProvider = MockCloudGrammarProvider()

        let adaptive = AdaptiveGrammarProvider(
            localProvider: localProvider,
            cloudProvider: GeminiGrammarProvider(),
            fallbackToCloud: true
        )

        #expect(adaptive.localProvider.isAvailable)
        let result = try await adaptive.rewrite(text: "Raw input", action: .fixGrammar)
        #expect(result.rewrittenText == "Local rewrite result")
        #expect(cloudProvider.callCount == 0)
    }

    @Test("Empty or whitespace-only response from Foundation Models throws rewriteFailed error")
    func test_empty_response_from_session_throws() async {
        let mockSession = MockFoundationSession(
            scriptedOutput: StructuredRewriteOutput(
                rewrittenText: "   ",
                changeSummary: "Empty result",
                estimatedWordCount: 0
            )
        )
        let provider = AppleFoundationGrammarProvider(
            sessionFactory: { mockSession },
            availabilityCheck: { .available }
        )

        await #expect(throws: GrammarError.self) {
            try await provider.rewrite(text: "Original transcript sentence", action: .fixGrammar)
        }
    }

    @Test("Rewrite to fit action passes target duration constraints to session")
    func test_rewrite_to_fit_passes_duration() async throws {
        let mockSession = MockFoundationSession(
            scriptedOutput: StructuredRewriteOutput(
                rewrittenText: "Fits duration cleanly.",
                changeSummary: "Shortened sentence",
                estimatedWordCount: 3
            )
        )
        let provider = AppleFoundationGrammarProvider(
            sessionFactory: { mockSession },
            availabilityCheck: { .available }
        )

        let targetDuration = CMTime(seconds: 2.0, preferredTimescale: 600)
        let result = try await provider.rewrite(text: "This is a sentence that will be rewritten to fit duration.", action: .rewriteToFit(targetDuration: targetDuration))

        #expect(result.rewrittenText == "Fits duration cleanly.")
        #expect(mockSession.lastAction == .rewriteToFit(targetDuration: targetDuration))
    }

    @Test("Live Apple Foundation Models system inference (opt-in)")
    func test_live_apple_foundation_model_inference() async throws {
        guard ProcessInfo.processInfo.environment["MACDUB_RUN_APPLE_MODEL_TESTS"] == "1" else {
            print("Skipping test_live_apple_foundation_model_inference: MACDUB_RUN_APPLE_MODEL_TESTS != 1")
            return
        }

        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            print("Skipping test_live_apple_foundation_model_inference: SystemLanguageModel is not available (\(model.availability))")
            return
        }

        let provider = AppleFoundationGrammarProvider()
        #expect(provider.isAvailable)

        let input = "this functions basically go and fetch all users"
        let result = try await provider.rewrite(text: input, action: .fixGrammar)

        #expect(!result.rewrittenText.isEmpty)
        #expect(result.rewrittenText != input)
        #expect(!result.diff.isEmpty)
        print("Live Apple Foundation Models rewrite result: '\(result.rewrittenText)'")
    }
}
