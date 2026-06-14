import Foundation
import ParallaxCore

/// In-memory `KeychainStoring` fake with programmable per-account behavior, so
/// `ServerStore` tests are deterministic on every runtime (no entitlement, so
/// no `errSecMissingEntitlement -34018`). Behavior is keyed by the account
/// string of `KeychainKey<Value>`. Values round-trip through the same JSON
/// path the real `Keychain` uses, keeping the fake type-faithful across the
/// generic `Value` while staying a single store.
final class FakeKeychain: KeychainStoring, @unchecked Sendable {
    /// What a `read` for a given account should do.
    enum ReadBehavior {
        /// Return a decoded value (encoded from `Value` at configure time).
        case value(Data)
        /// Return nil — the token is CONFIRMED absent (prune-eligible).
        case absent
        /// Throw — a Keychain read ERROR (locked device / missing entitlement),
        /// which must NOT prune the persisted record.
        case error(Error)
    }

    enum FakeError: Error { case notConfigured }

    private let lock = NSLock()
    private var behaviors: [String: ReadBehavior] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // Call records for assertions.
    private(set) var storeCalls: [String] = []
    private(set) var deleteCalls: [String] = []

    init() {}

    // MARK: - Programming the fake

    /// Make reads for `key`'s account return `value`.
    func setValue<Value: Codable & Sendable>(_ value: Value, for key: KeychainKey<Value>) throws {
        let data = try encoder.encode(value)
        lock.withLock { behaviors[key.account] = .value(data) }
    }

    /// Make reads for `account` return nil (confirmed-absent).
    func setAbsent(account: String) {
        lock.withLock { behaviors[account] = .absent }
    }

    /// Make reads for `account` throw `error` (a read FAULT, not a confirmed nil).
    func setReadError(account: String, error: Error) {
        lock.withLock { behaviors[account] = .error(error) }
    }

    // MARK: - KeychainStoring

    func store<Value: Codable & Sendable>(_ value: Value, for key: KeychainKey<Value>) async throws {
        let data = try encoder.encode(value)
        lock.withLock {
            storeCalls.append(key.account)
            behaviors[key.account] = .value(data)
        }
    }

    func read<Value: Codable & Sendable>(_ key: KeychainKey<Value>) async throws -> Value? {
        let behavior = lock.withLock { behaviors[key.account] }
        switch behavior {
        case .value(let data):
            return try decoder.decode(Value.self, from: data)
        case .absent:
            return nil
        case .error(let error):
            throw error
        case nil:
            // Unconfigured account behaves like the real Keychain's
            // errSecItemNotFound: a confirmed-absent nil.
            return nil
        }
    }

    func delete<Value: Codable & Sendable>(_ key: KeychainKey<Value>) async throws {
        lock.withLock {
            deleteCalls.append(key.account)
            behaviors.removeValue(forKey: key.account)
        }
    }
}
