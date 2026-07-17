import Foundation
import ParallaxCore

/// In-memory `KeychainStoring` fake with programmable per-account behavior, so
/// store-layer tests are deterministic on every runtime (no entitlement, so no
/// `errSecMissingEntitlement -34018`). Behavior is keyed by the account string
/// of `KeychainKey<Value>`. Values round-trip through the same JSON path the
/// real `Keychain` uses, keeping the fake type-faithful across the generic
/// `Value` while staying a single store.
public final class FakeKeychain: KeychainStoring, @unchecked Sendable {
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

    private let lock = NSLock()
    private var behaviors: [String: ReadBehavior] = [:]
    private var _storeCalls: [String] = []
    private var _deleteCalls: [String] = []

    // Call records for assertions. Lock-guarded so an assertion can race an
    // in-flight call without undefined behavior.
    public var storeCalls: [String] { lock.withLock { _storeCalls } }
    public var deleteCalls: [String] { lock.withLock { _deleteCalls } }

    public init() {}

    // MARK: - Programming the fake

    /// Make reads for `key`'s account return `value`.
    public func setValue<Value: Codable & Sendable>(_ value: Value, for key: KeychainKey<Value>) throws {
        let data = try JSONEncoder().encode(value)
        lock.withLock { behaviors[key.account] = .value(data) }
    }

    /// Make reads for `account` return nil (confirmed-absent).
    public func setAbsent(account: String) {
        lock.withLock { behaviors[account] = .absent }
    }

    /// Make reads for `account` throw `error` (a read FAULT, not a confirmed nil).
    public func setReadError(account: String, error: Error) {
        lock.withLock { behaviors[account] = .error(error) }
    }

    // MARK: - KeychainStoring

    public func store<Value: Codable & Sendable>(_ value: Value, for key: KeychainKey<Value>) async throws {
        let data = try JSONEncoder().encode(value)
        lock.withLock {
            _storeCalls.append(key.account)
            behaviors[key.account] = .value(data)
        }
    }

    public func read<Value: Codable & Sendable>(_ key: KeychainKey<Value>) async throws -> Value? {
        let behavior = lock.withLock { behaviors[key.account] }
        switch behavior {
        case .value(let data):
            return try JSONDecoder().decode(Value.self, from: data)
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

    public func delete<Value: Codable & Sendable>(_ key: KeychainKey<Value>) async throws {
        lock.withLock {
            _deleteCalls.append(key.account)
            behaviors.removeValue(forKey: key.account)
        }
    }
}
