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
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            return key.defaultValue
        }
    }

    public func set<Value>(_ value: Value, for key: SettingKey<Value>) {
        do {
            let data = try encoder.encode(value)
            defaults.set(data, forKey: key.name)
        } catch {
            // Encoding failures shouldn't be possible for valid Codable types; if they happen, drop the write silently.
        }
    }

    public func remove<Value>(_ key: SettingKey<Value>) {
        defaults.removeObject(forKey: key.name)
    }
}
