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
