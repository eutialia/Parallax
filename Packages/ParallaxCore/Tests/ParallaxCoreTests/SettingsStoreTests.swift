import Testing
import Foundation
@testable import ParallaxCore

@Suite("SettingsStore")
struct SettingsStoreTests {
    @Test("returns default value when no value is stored")
    func defaultValue() async {
        let defaults = UserDefaults(suiteName: "test-defaults-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        let key = SettingKey<Int>(name: "test.int", defaultValue: 42)
        let value = await store.value(for: key)
        #expect(value == 42)
    }

    @Test("returns stored value after set")
    func setAndGet() async throws {
        let defaults = UserDefaults(suiteName: "test-defaults-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        let key = SettingKey<String>(name: "test.string", defaultValue: "default")
        try await store.set("override", for: key)
        let value = await store.value(for: key)
        #expect(value == "override")
    }

    @Test("supports Codable struct values")
    func codableValues() async throws {
        struct Foo: Codable, Equatable, Sendable {
            let bar: Int
            let baz: String
        }
        let defaults = UserDefaults(suiteName: "test-defaults-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        let key = SettingKey<Foo>(name: "test.foo", defaultValue: Foo(bar: 0, baz: "x"))
        try await store.set(Foo(bar: 7, baz: "hello"), for: key)
        let value = await store.value(for: key)
        #expect(value == Foo(bar: 7, baz: "hello"))
    }

    @Test("removing a key restores the default")
    func removeRestoresDefault() async throws {
        let defaults = UserDefaults(suiteName: "test-defaults-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        let key = SettingKey<Int>(name: "test.removable", defaultValue: 100)
        try await store.set(7, for: key)
        await store.remove(key)
        let value = await store.value(for: key)
        #expect(value == 100)
    }

    @Test("tryValue returns nil when no value is stored")
    func tryValueMissing() async throws {
        let defaults = UserDefaults(suiteName: "test-defaults-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        let key = SettingKey<Int>(name: "test.try.missing", defaultValue: 0)
        let value = try await store.tryValue(for: key)
        #expect(value == nil)
    }

    @Test("tryValue returns stored value after set")
    func tryValueRoundTrip() async throws {
        let defaults = UserDefaults(suiteName: "test-defaults-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        let key = SettingKey<String>(name: "test.try.string", defaultValue: "default")
        try await store.set("hello", for: key)
        let value = try await store.tryValue(for: key)
        #expect(value == "hello")
    }

    @Test("tryValue throws SettingsError.decodingFailed when stored data does not decode (schema mismatch)")
    func tryValueSurfacesDecodeFailure() async throws {
        struct V1: Codable, Sendable { let a: Int }
        struct V2: Codable, Sendable { let a: Int; let required: String }
        let suite = "test-defaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(defaults: defaults)
        let keyV1 = SettingKey<V1>(name: "schema.evolution", defaultValue: V1(a: 0))
        let keyV2 = SettingKey<V2>(name: "schema.evolution", defaultValue: V2(a: 0, required: ""))

        try await store.set(V1(a: 7), for: keyV1)

        await #expect(throws: SettingsStore.SettingsError.self) {
            _ = try await store.tryValue(for: keyV2)
        }
    }

    @Test("set surfaces encoding failures as SettingsError")
    func encodingFailureSurfaces() async {
        struct Unencodable: Codable, Sendable {
            let value: Double
            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(value) // NaN / Infinity fails by default
            }
            init(value: Double) { self.value = value }
            init(from decoder: Decoder) throws {
                self.value = try decoder.singleValueContainer().decode(Double.self)
            }
        }
        let defaults = UserDefaults(suiteName: "test-defaults-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        let key = SettingKey<Unencodable>(
            name: "test.unencodable",
            defaultValue: Unencodable(value: 0)
        )

        await #expect(throws: SettingsStore.SettingsError.self) {
            try await store.set(Unencodable(value: .infinity), for: key)
        }
    }
}
