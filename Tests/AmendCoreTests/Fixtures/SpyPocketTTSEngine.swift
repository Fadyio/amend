import Foundation
@testable import AmendCore

/// Test spy engine conforming to `PocketTTSEngine`.
/// Tracks calls and allows tests to simulate voice cloning and synthesis without touching FluidAudio internals.
public final class SpyPocketTTSEngine: PocketTTSEngine, @unchecked Sendable {
    public var cloneHandler: (@Sendable (URL) async throws -> PocketTTSVoiceHandle)?
    public var synthesizeHandleHandler: (@Sendable (String, PocketTTSVoiceHandle) async throws -> Data)?
    public var synthesizeVoiceIDHandler: (@Sendable (String, String?) async throws -> Data)?
    public var initializeHandler: (@Sendable () async throws -> Void)?
    public var cleanupHandler: (@Sendable () async -> Void)?

    public private(set) var initializeCalls: Int = 0
    public private(set) var cloneCalls: [URL] = []
    public private(set) var synthesizeCalls: [(text: String, handle: PocketTTSVoiceHandle?)] = []
    public private(set) var cleanupCalls: Int = 0
    private let lock = NSLock()

    public var isAvailable: Bool = true

    public init() {}

    public func initialize() async throws {
        lock.withLock { initializeCalls += 1 }
        if let handler = initializeHandler {
            try await handler()
        }
    }

    public func cloneVoice(from url: URL) async throws -> PocketTTSVoiceHandle {
        lock.withLock { cloneCalls.append(url) }
        if let handler = cloneHandler {
            return try await handler(url)
        }
        return PocketTTSVoiceHandle(identifier: url.lastPathComponent)
    }

    public func synthesize(text: String, voiceHandle: PocketTTSVoiceHandle) async throws -> Data {
        lock.withLock { synthesizeCalls.append((text: text, handle: voiceHandle)) }
        if let handler = synthesizeHandleHandler {
            return try await handler(text, voiceHandle)
        }
        return Data()
    }

    public func synthesize(text: String, voiceID: String?) async throws -> Data {
        lock.withLock { synthesizeCalls.append((text: text, handle: nil)) }
        if let handler = synthesizeVoiceIDHandler {
            return try await handler(text, voiceID)
        }
        return Data()
    }

    public func cleanup() async {
        lock.withLock { cleanupCalls += 1 }
        if let handler = cleanupHandler {
            await handler()
        }
    }
}
