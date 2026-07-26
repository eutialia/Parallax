import Foundation
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxCore

/// The entitled-host contract for the REAL keychain. Everything that merely needs a keychain
/// (store layers, sign-in flows) runs on `FakeKeychain` instead — this suite exists only to prove
/// the `SecItem` plumbing behind it behaves as those fakes assume.
@Suite(
    "Keychain",
    .enabled(
        if: KeychainEntitlementProbe.hasKeychainAccess,
        "test host lacks the keychain entitlement (errSecMissingEntitlement -34018)"
    )
)
struct KeychainTests {
    private static let service = "com.lhdev.parallax.tests"

    private struct Token: Codable, Equatable, Sendable {
        let access: String
        let refresh: String
    }

    /// Runs `body` with a keychain and a UUID-unique key, then deletes the item — including when
    /// an expectation inside failed, which previously left orphans in the host's real keychain.
    private func withKey<Value: Codable & Sendable>(
        _ type: Value.Type = Value.self,
        label: String,
        _ body: (Keychain, KeychainKey<Value>) async throws -> Void
    ) async throws {
        let keychain = Keychain(service: Self.service)
        let key = KeychainKey<Value>(account: "\(label)-\(UUID().uuidString)")
        do {
            try await body(keychain, key)
        } catch {
            try? await keychain.delete(key)
            throw error
        }
        try await keychain.delete(key)
    }

    /// One generic path for every `Value`: the phantom type on `KeychainKey` is what keeps the
    /// stored JSON and the read type in step, so the same flow must hold for a scalar and a struct.
    private func assertRoundTrips<Value: Codable & Sendable & Equatable>(
        _ value: Value,
        label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await withKey(Value.self, label: label) { keychain, key in
            try await keychain.store(value, for: key)
            let stored = try await keychain.read(key)
            #expect(stored == value, sourceLocation: sourceLocation)
        }
    }

    @Test("stored values read back identical, whatever the value type")
    func storeAndRead() async throws {
        try await assertRoundTrips("hello", label: "roundtrip-string")
        try await assertRoundTrips(Token(access: "a", refresh: "b"), label: "roundtrip-token")
    }

    @Test("reading an absent account returns nil rather than throwing")
    func readMissing() async throws {
        try await withKey(String.self, label: "missing") { keychain, key in
            let read = try await keychain.read(key)
            #expect(read == nil)
        }
    }

    @Test("delete removes the item")
    func delete() async throws {
        try await withKey(String.self, label: "delete") { keychain, key in
            try await keychain.store("bye", for: key)
            try await keychain.delete(key)
            let read = try await keychain.read(key)
            #expect(read == nil)
        }
    }

    /// A second store must UPDATE, not fail on `errSecDuplicateItem` — every credential rotation
    /// in the app writes over an existing account.
    @Test("storing twice overwrites instead of duplicating")
    func updateValue() async throws {
        try await withKey(String.self, label: "update") { keychain, key in
            try await keychain.store("first", for: key)
            try await keychain.store("second", for: key)
            let read = try await keychain.read(key)
            #expect(read == "second")
        }
    }
}
