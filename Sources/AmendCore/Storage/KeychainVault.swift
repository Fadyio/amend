import Foundation
import Security

public enum ServiceKey: String, CaseIterable, Sendable, Codable {
    case elevenLabs = "ElevenLabs"
    case resemble = "Resemble"
    case gemini = "Gemini"
}

public protocol CredentialVaultProtocol: Sendable {
    func save(key: String, for service: ServiceKey) throws
    func get(keyFor service: ServiceKey) throws -> String?
    func delete(keyFor service: ServiceKey) throws
    func has(keyFor service: ServiceKey) -> Bool
}

public enum KeychainVaultError: LocalizedError, Equatable {
    case duplicateItem
    case itemNotFound
    case unhandledStatus(OSStatus)
    case dataConversionError
    case invalidInput(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateItem:
            return "Item already exists in Keychain."
        case .itemNotFound:
            return "Item not found in Keychain."
        case .unhandledStatus(let status):
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
            return "Keychain error: OSStatus \(status) - \(msg)"
        case .dataConversionError:
            return "Failed to convert Keychain data to UTF-8 string."
        case .invalidInput(let reason):
            return "Invalid credential input: \(reason)"
        }
    }
}

public final class KeychainVault: CredentialVaultProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    public let serviceIdentifier: String
    private let accessGroup: String?

    public init(serviceIdentifier: String = "com.fady.amend", accessGroup: String? = nil) {
        self.serviceIdentifier = serviceIdentifier
        self.accessGroup = accessGroup
    }

    public func save(key: String, for service: ServiceKey) throws {
        KeychainVault.lock.lock()
        defer { KeychainVault.lock.unlock() }

        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KeychainVaultError.invalidInput("API key cannot be empty or whitespace.")
        }
        guard let keyData = trimmed.data(using: .utf8) else {
            throw KeychainVaultError.dataConversionError
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: service.rawValue,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Item exists -> update it
            var updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceIdentifier,
                kSecAttrAccount as String: service.rawValue
            ]
            if let accessGroup = accessGroup {
                updateQuery[kSecAttrAccessGroup as String] = accessGroup
            }

            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: keyData
            ]

            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributesToUpdate as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainVaultError.unhandledStatus(updateStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainVaultError.unhandledStatus(status)
        }
    }

    public func get(keyFor service: ServiceKey) throws -> String? {
        KeychainVault.lock.lock()
        defer { KeychainVault.lock.unlock() }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: service.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainVaultError.unhandledStatus(status)
        }
        guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
            throw KeychainVaultError.dataConversionError
        }
        return string
    }

    public func delete(keyFor service: ServiceKey) throws {
        KeychainVault.lock.lock()
        defer { KeychainVault.lock.unlock() }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: service.rawValue
        ]
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainVaultError.unhandledStatus(status)
        }
    }

    public func has(keyFor service: ServiceKey) -> Bool {
        KeychainVault.lock.lock()
        defer { KeychainVault.lock.unlock() }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: service.rawValue,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }
}

public final class MockCredentialVault: CredentialVaultProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ServiceKey: String] = [:]

    public init(initialValues: [ServiceKey: String] = [:]) {
        self.storage = initialValues
    }

    public func save(key: String, for service: ServiceKey) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KeychainVaultError.invalidInput("API key cannot be empty or whitespace.")
        }
        lock.lock()
        defer { lock.unlock() }
        storage[service] = trimmed
    }

    public func get(keyFor service: ServiceKey) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[service]
    }

    public func delete(keyFor service: ServiceKey) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: service)
    }

    public func has(keyFor service: ServiceKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage[service] != nil
    }
}
