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
        // value should not crash the app on launch.
        return (try? decoder.decode(Value.self, from: data)) ?? key.defaultValue
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
