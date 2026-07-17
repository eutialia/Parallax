import Testing
import Foundation
import ParallaxCoreTestSupport
@testable import ParallaxCore

@Suite(
    "Keychain",
    .enabled(
        if: KeychainEntitlementProbe.hasKeychainAccess,
        "test host lacks the keychain entitlement (errSecMissingEntitlement -34018)"
    )
)
struct KeychainTests {
    private static let service = "com.lhdev.parallax.tests"

    @Test("store and read round-trip a Codable value")
    func storeAndRead() async throws {
        let keychain = Keychain(service: Self.service)
        let key = KeychainKey<String>(account: "test-roundtrip-\(UUID().uuidString)")

        try await keychain.store("hello", for: key)
        let read = try await keychain.read(key)
        #expect(read == "hello")

        try await keychain.delete(key)
    }

    @Test("read returns nil for a missing key")
    func readMissing() async throws {
        let keychain = Keychain(service: Self.service)
        let key = KeychainKey<String>(account: "missing-\(UUID().uuidString)")
        let read = try await keychain.read(key)
        #expect(read == nil)
    }

    @Test("delete removes the value")
    func delete() async throws {
        let keychain = Keychain(service: Self.service)
        let key = KeychainKey<String>(account: "test-delete-\(UUID().uuidString)")
        try await keychain.store("bye", for: key)
        try await keychain.delete(key)
        let read = try await keychain.read(key)
        #expect(read == nil)
    }

    @Test("storing twice updates the value")
    func updateValue() async throws {
        let keychain = Keychain(service: Self.service)
        let key = KeychainKey<String>(account: "test-update-\(UUID().uuidString)")

        try await keychain.store("first", for: key)
        try await keychain.store("second", for: key)
        let read = try await keychain.read(key)
        #expect(read == "second")

        try await keychain.delete(key)
    }

    @Test("phantom type prevents cross-type read at compile time via key identity")
    func typedKeys() async throws {
        struct Token: Codable, Equatable, Sendable {
            let access: String
            let refresh: String
        }
        let keychain = Keychain(service: Self.service)
        let key = KeychainKey<Token>(account: "test-typed-\(UUID().uuidString)")

        let token = Token(access: "a", refresh: "b")
        try await keychain.store(token, for: key)
        let read = try await keychain.read(key)
        #expect(read == token)

        try await keychain.delete(key)
    }
}
