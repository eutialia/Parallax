import Foundation
import ParallaxCore

/// In-memory `KeychainStoring` fake for app-target tests. Values round-trip through
/// the same JSON encoding path as the real `Keychain`.
final class FakeKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Data] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {}

    func setValue<Value: Codable & Sendable>(_ value: Value, for key: KeychainKey<Value>) throws {
        let data = try encoder.encode(value)
        lock.withLock { store[key.account] = data }
    }

    // MARK: - KeychainStoring

    func store<Value: Codable & Sendable>(_ value: Value, for key: KeychainKey<Value>) async throws {
        let data = try encoder.encode(value)
        lock.withLock { store[key.account] = data }
    }

    func read<Value: Codable & Sendable>(_ key: KeychainKey<Value>) async throws -> Value? {
        guard let data = lock.withLock({ store[key.account] }) else { return nil }
        return try decoder.decode(Value.self, from: data)
    }

    func delete<Value: Codable & Sendable>(_ key: KeychainKey<Value>) async throws {
        lock.withLock { store.removeValue(forKey: key.account) }
    }
}
