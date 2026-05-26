import Testing
import Foundation
@testable import ParallaxCore

@Suite("Keychain")
struct KeychainTests {
    @Test("store and read round-trip a value")
    func storeAndRead() async throws {
        let keychain = Keychain(service: "com.lhdev.parallax.tests")
        let key = KeychainKey(account: "test-roundtrip-\(UUID().uuidString)")
        let payload = Data("hello".utf8)

        try await keychain.store(payload, for: key)
        defer { Task { try? await keychain.delete(key) } }

        let read = try await keychain.read(key)
        #expect(read == payload)
    }

    @Test("read returns nil for a missing key")
    func readMissing() async throws {
        let keychain = Keychain(service: "com.lhdev.parallax.tests")
        let key = KeychainKey(account: "missing-\(UUID().uuidString)")
        let read = try await keychain.read(key)
        #expect(read == nil)
    }

    @Test("delete removes the value")
    func delete() async throws {
        let keychain = Keychain(service: "com.lhdev.parallax.tests")
        let key = KeychainKey(account: "test-delete-\(UUID().uuidString)")
        try await keychain.store(Data("bye".utf8), for: key)
        try await keychain.delete(key)
        let read = try await keychain.read(key)
        #expect(read == nil)
    }

    @Test("storing twice updates the value")
    func updateValue() async throws {
        let keychain = Keychain(service: "com.lhdev.parallax.tests")
        let key = KeychainKey(account: "test-update-\(UUID().uuidString)")
        defer { Task { try? await keychain.delete(key) } }

        try await keychain.store(Data("first".utf8), for: key)
        try await keychain.store(Data("second".utf8), for: key)
        let read = try await keychain.read(key)
        #expect(read == Data("second".utf8))
    }
}
