import Foundation

public struct SettingKey<Value: Codable & Sendable>: Sendable {
    public let name: String
    public let defaultValue: Value

    public init(name: String, defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

public actor SettingsStore {
    public enum SettingsError: Error, Sendable {
        case encodingFailed(underlying: String)
        case decodingFailed(key: String, underlying: String)
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func value<Value>(for key: SettingKey<Value>) -> Value {
        guard let data = defaults.data(forKey: key.name) else {
            return key.defaultValue
        }
        // Decode failures fall back to the default — a corrupted/migrated
        // value should not crash the app on launch. Callers that care about
        // distinguishing missing-vs-corrupt (e.g. ServerStore, which would
        // rather refuse to wipe data than silently lose it) should use
        // `tryValue(for:)` instead.
        return (try? decoder.decode(Value.self, from: data)) ?? key.defaultValue
    }

    /// Returns the stored value, or `nil` if nothing is stored. Throws
    /// `SettingsError.decodingFailed` when data exists but cannot decode —
    /// preventing silent data loss on schema mismatches.
    public func tryValue<Value>(for key: SettingKey<Value>) throws -> Value? {
        guard let data = defaults.data(forKey: key.name) else { return nil }
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            throw SettingsError.decodingFailed(key: key.name, underlying: String(describing: error))
        }
    }

    /// Decodes the raw stored bytes for `key` as an arbitrary `Decodable` `T`,
    /// independent of the key's declared `Value`. Returns `nil` when nothing is
    /// stored or when the bytes don't decode as `T` — never throws. The escape
    /// hatch for recovery reads that must tolerate a shape the key's `Value`
    /// can't express (e.g. an element-tolerant `[Failable<…>]` decode that drops
    /// incompatible rows). Reuses the same `JSONDecoder` as `value`/`tryValue`,
    /// so it sees byte-identical input.
    public func decode<T: Decodable>(_ type: T.Type, for key: SettingKey<some Codable & Sendable>) -> T? {
        guard let data = defaults.data(forKey: key.name) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    public func set<Value>(_ value: Value, for key: SettingKey<Value>) throws {
        do {
            let data = try encoder.encode(value)
            defaults.set(data, forKey: key.name)
        } catch {
            throw SettingsError.encodingFailed(underlying: String(describing: error))
        }
    }

    public func remove<Value>(_ key: SettingKey<Value>) {
        defaults.removeObject(forKey: key.name)
    }
}
