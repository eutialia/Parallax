import Foundation
import Testing
@testable import ParallaxCore

@Suite("SettingsStore")
struct SettingsStoreTests {
    private struct Profile: Codable, Equatable, Sendable {
        let bar: Int
        let baz: String
    }

    /// Runs `body` against a store backed by a throwaway `UserDefaults` suite, then deletes the
    /// suite. The seven copies of this preamble it replaces had no teardown, so every run left a
    /// domain behind in the host's preferences store.
    private func withStore(
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: (SettingsStore) async throws -> Void
    ) async throws {
        let suiteName = "test-defaults-\(UUID().uuidString)"
        let defaults = try #require(
            UserDefaults(suiteName: suiteName), "isolated defaults suite", sourceLocation: sourceLocation
        )
        // Cleanup goes through `.standard` so the suite's own instance isn't captured here —
        // sending it into the actor below and holding it in a closure would be a data race.
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        try await body(SettingsStore(defaults: defaults))
    }

    @Test("an unset key reads its declared default")
    func defaultValue() async throws {
        try await withStore { store in
            #expect(await store.value(for: SettingKey(name: "test.int", defaultValue: 42)) == 42)
        }
    }

    @Test("a set value overrides the default")
    func setAndGet() async throws {
        try await withStore { store in
            let key = SettingKey<String>(name: "test.string", defaultValue: "default")
            try await store.set("override", for: key)
            #expect(await store.value(for: key) == "override")
        }
    }

    @Test("Codable struct values survive the round trip")
    func codableValues() async throws {
        try await withStore { store in
            let key = SettingKey(name: "test.profile", defaultValue: Profile(bar: 0, baz: "x"))
            try await store.set(Profile(bar: 7, baz: "hello"), for: key)
            #expect(await store.value(for: key) == Profile(bar: 7, baz: "hello"))
        }
    }

    /// `value(for:)` deliberately swallows a decode failure so a migrated/corrupt preference
    /// can't crash launch — the distinction is `tryValue`'s job, tested below.
    @Test("value(for:) falls back to the default when the stored bytes don't decode")
    func corruptValueFallsBackToDefault() async throws {
        try await withStore { store in
            let stored = SettingKey(name: "schema.evolution", defaultValue: Profile(bar: 0, baz: ""))
            try await store.set(Profile(bar: 7, baz: "hi"), for: stored)

            let reread = SettingKey<Int>(name: "schema.evolution", defaultValue: -1)
            #expect(await store.value(for: reread) == -1)
        }
    }

    @Test("tryValue reports nothing-stored as nil, not as the default")
    func tryValueMissing() async throws {
        try await withStore { store in
            let value = try await store.tryValue(for: SettingKey(name: "test.try.missing", defaultValue: 0))
            #expect(value == nil)
        }
    }

    @Test("tryValue returns the stored value once set")
    func tryValueRoundTrip() async throws {
        try await withStore { store in
            let key = SettingKey<String>(name: "test.try.string", defaultValue: "default")
            try await store.set("hello", for: key)
            let value = try await store.tryValue(for: key)
            #expect(value == "hello")
        }
    }

    /// A schema mismatch must be loud here: the callers that use `tryValue` (ServerStore) would
    /// rather refuse to touch the data than silently overwrite it with a default.
    @Test("tryValue throws on a schema mismatch instead of returning the default")
    func tryValueSurfacesDecodeFailure() async throws {
        struct V1: Codable, Sendable { let a: Int }
        struct V2: Codable, Sendable { let a: Int; let required: String }

        try await withStore { store in
            try await store.set(V1(a: 7), for: SettingKey(name: "schema.evolution", defaultValue: V1(a: 0)))

            await #expect(throws: SettingsStore.SettingsError.self) {
                _ = try await store.tryValue(
                    for: SettingKey(name: "schema.evolution", defaultValue: V2(a: 0, required: ""))
                )
            }
        }
    }

    @Test("set surfaces an encoding failure rather than storing nothing silently")
    func encodingFailureSurfaces() async throws {
        struct Unencodable: Codable, Sendable {
            let value: Double
            init(value: Double) { self.value = value }
            init(from decoder: Decoder) throws {
                value = try decoder.singleValueContainer().decode(Double.self)
            }
            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(value)   // NaN / Infinity fails by default
            }
        }

        try await withStore { store in
            let key = SettingKey(name: "test.unencodable", defaultValue: Unencodable(value: 0))
            await #expect(throws: SettingsStore.SettingsError.self) {
                try await store.set(Unencodable(value: .infinity), for: key)
            }
        }
    }

    // MARK: - decode(_:for:) recovery hatch

    /// The recovery read: decode the raw bytes as a shape the key's own `Value` can't express
    /// (here, a tolerant per-element wrapper over a list one of whose rows changed shape).
    @Test("decode(_:for:) reads the stored bytes as an unrelated Decodable")
    func decodeReadsAnAlternateShape() async throws {
        try await withStore { store in
            let key = SettingKey(name: "recovery.profile", defaultValue: Profile(bar: 0, baz: ""))
            try await store.set(Profile(bar: 3, baz: "kept"), for: key)

            struct PartialProfile: Decodable { let baz: String }
            let recovered = await store.decode(PartialProfile.self, for: key)
            #expect(recovered?.baz == "kept")
        }
    }

    @Test("decode(_:for:) returns nil rather than throwing when the shape doesn't fit")
    func decodeReturnsNilOnMismatch() async throws {
        try await withStore { store in
            let key = SettingKey(name: "recovery.profile", defaultValue: Profile(bar: 0, baz: ""))
            try await store.set(Profile(bar: 3, baz: "kept"), for: key)

            #expect(await store.decode([Int].self, for: key) == nil)
        }
    }

    @Test("decode(_:for:) returns nil when nothing is stored")
    func decodeReturnsNilWhenAbsent() async throws {
        try await withStore { store in
            let key = SettingKey(name: "recovery.absent", defaultValue: Profile(bar: 0, baz: ""))
            #expect(await store.decode(Profile.self, for: key) == nil)
        }
    }
}
