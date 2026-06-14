import Foundation
import Security

/// The seam over secret storage that consumers depend on instead of the
/// concrete `Keychain`. The generic `Value` lives on each method (not the
/// protocol), so it's usable as `any KeychainStoring` while still keeping the
/// phantom-typed `KeychainKey<Value>` contract. Conformers are free to be
/// actors (`Keychain`) or plain test fakes — the requirements are `async` so
/// cross-actor isolation is satisfied either way.
public protocol KeychainStoring: Sendable {
    func store<Value: Codable & Sendable>(_ value: Value, for key: KeychainKey<Value>) async throws
    func read<Value: Codable & Sendable>(_ key: KeychainKey<Value>) async throws -> Value?
    func delete<Value: Codable & Sendable>(_ key: KeychainKey<Value>) async throws
}

public actor Keychain: KeychainStoring {
    public enum KeychainError: Error, Sendable {
        case unexpectedStatus(OSStatus)
        case encodingFailed(underlying: String)
        case decodingFailed(underlying: String)
    }

    private let service: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(service: String) {
        self.service = service
    }

    public func store<Value: Codable & Sendable>(_ value: Value, for key: KeychainKey<Value>) throws {
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw KeychainError.encodingFailed(underlying: String(describing: error))
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            for (k, v) in attributes { addQuery[k] = v }
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func read<Value: Codable & Sendable>(_ key: KeychainKey<Value>) throws -> Value? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            do {
                return try decoder.decode(Value.self, from: data)
            } catch {
                throw KeychainError.decodingFailed(underlying: String(describing: error))
            }
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func delete<Value: Codable & Sendable>(_ key: KeychainKey<Value>) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
