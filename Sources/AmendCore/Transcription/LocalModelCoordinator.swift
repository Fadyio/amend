import Foundation
import CoreML
import OSLog

public enum ManagedModelType: String, Sendable, CaseIterable {
    case asr = "Parakeet ASR"
    case vad = "Silero VAD"
    case tts = "PocketTTS"
    case llm = "Local Foundation Model"
}

public enum ModelLifecycleState: Equatable, Sendable {
    case idle
    case active(ManagedModelType)
    case transitioning(from: ManagedModelType?, to: ManagedModelType)
}

public enum ModelCoordinatorError: Error, LocalizedError {
    case resourceBusy(ManagedModelType)
    case modelNotLoaded(ManagedModelType)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .resourceBusy(let type):
            return "Local model coordinator busy executing \(type.rawValue)"
        case .modelNotLoaded(let type):
            return "Model \(type.rawValue) is not loaded"
        case .executionFailed(let reason):
            return "Model execution failed: \(reason)"
        }
    }
}

/// Central coordinator enforcing serialized local model lifecycle for 8GB Apple Silicon Macs (ADR-0009).
/// Strictly guarantees mutual exclusion: ASR resources are released before PocketTTS is loaded.
public actor LocalModelCoordinator {
    public static let shared = LocalModelCoordinator()

    private let logger = Logger(subsystem: "com.fady.amend", category: "LocalModelCoordinator")
    public private(set) var currentState: ModelLifecycleState = .idle
    private var activeModelType: ManagedModelType?

    // Registered teardown hooks for freeing Core ML / GPU resources
    private var teardownHooks: [ManagedModelType: @Sendable () async -> Void] = [:]

    // Non-reentrant FIFO lease queue to prevent actor reentrancy interleaving across suspension points
    private var isLocked: Bool = false
    private var waitQueue: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func registerTeardown(for type: ManagedModelType, hook: @escaping @Sendable () async -> Void) {
        teardownHooks[type] = hook
    }

    private func lockQueue() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waitQueue.append(continuation)
        }
    }

    private func unlockQueue() {
        if !waitQueue.isEmpty {
            let next = waitQueue.removeFirst()
            next.resume()
        } else {
            isLocked = false
        }
    }

    /// Acquires exclusive execution permission for a given model type.
    /// If another model is active, its teardown hook is called and completed before granting access.
    public func acquireExclusiveAccess(for targetType: ManagedModelType) async throws {
        if let current = activeModelType, current != targetType {
            logger.info("Releasing \(current.rawValue) before activating \(targetType.rawValue)")
            currentState = .transitioning(from: current, to: targetType)
            if let teardown = teardownHooks[current] {
                await teardown()
            }
            activeModelType = nil
        }

        activeModelType = targetType
        currentState = .active(targetType)
        logger.info("Exclusive access granted to \(targetType.rawValue)")
    }

    /// Releases exclusive access for the given model type.
    public func releaseAccess(for type: ManagedModelType) async {
        guard activeModelType == type else { return }
        logger.info("Releasing \(type.rawValue)")
        if let teardown = teardownHooks[type] {
            await teardown()
        }
        activeModelType = nil
        currentState = .idle
    }

    /// Convenience wrapper to run an inference job with guaranteed exclusive lifecycle management.
    /// Strictly non-reentrant across async suspension points.
    public func withExclusiveModel<T: Sendable>(
        _ type: ManagedModelType,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        await lockQueue()
        defer { unlockQueue() }

        try await acquireExclusiveAccess(for: type)
        do {
            let result = try await operation()
            await releaseAccess(for: type)
            return result
        } catch {
            await releaseAccess(for: type)
            throw error
        }
    }

    /// Force unloads all models and returns to idle state.
    public func releaseAll() async {
        if let current = activeModelType, let teardown = teardownHooks[current] {
            await teardown()
        }
        activeModelType = nil
        currentState = .idle
        logger.info("All local models released and coordinator idle")
    }
}
