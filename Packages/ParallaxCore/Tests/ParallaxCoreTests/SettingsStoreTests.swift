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
    func setAndGet() async {
        let defaults = UserDefaults(suiteName: "test-defaults-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        let key = SettingKey<String>(name: "test.string", defaultValue: "default")
        await store.set("override", for: key)
        let value = await store.value(for: key)
        #expect(value == "override")
    }

    @Test("supports Codable struct values")
    func codableValues() async {
        struct Foo: Codable, Equatable, Sendable {
            let bar: Int
            let baz: String
        }
        let defaults = UserDefaults(suiteName: "test-defaults-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        let key = SettingKey<Foo>(name: "test.foo", defaultValue: Foo(bar: 0, baz: "x"))
        await store.set(Foo(bar: 7, baz: "hello"), for: key)
        let value = await store.value(for: key)
        #expect(value == Foo(bar: 7, baz: "hello"))
    }

    @Test("removing a key restores the default")
    func removeRestoresDefault() async {
        let defaults = UserDefaults(suiteName: "test-defaults-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        let key = SettingKey<Int>(name: "test.removable", defaultValue: 100)
        await store.set(7, for: key)
        await store.remove(key)
        let value = await store.value(for: key)
        #expect(value == 100)
    }
}
