import Foundation
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxCore

/// The fake is what every store-layer suite in this repo (and in ParallaxJellyfin) actually runs
/// against, and the app target keeps a deliberate second copy of it. Nothing pinned its behaviour
/// until now, so a drift between the two copies — or between the fake and the real `Keychain` —
/// would have surfaced as a mystery failure in an unrelated suite.
@Suite("FakeKeychain contract")
struct FakeKeychainTests {
    private struct Token: Codable, Equatable, Sendable {
        let access: String
        let refresh: String
    }

    private let key = KeychainKey<Token>(account: "server-1")
    private let token = Token(access: "a", refresh: "b")

    @Test("a stored value reads back through the same JSON path the real keychain uses")
    func storeAndRead() async throws {
        let keychain = FakeKeychain()
        try await keychain.store(token, for: key)

        let read = try await keychain.read(key)
        #expect(read == token)
        #expect(keychain.storeCalls == [key.account])
    }

    /// An unconfigured account behaves like `errSecItemNotFound`: a CONFIRMED nil, not a fault.
    @Test("an unconfigured account reads as confirmed-absent")
    func unconfiguredAccountIsAbsent() async throws {
        let read = try await FakeKeychain().read(key)
        #expect(read == nil)
    }

    @Test("an explicitly absent account also reads nil")
    func explicitAbsence() async throws {
        let keychain = FakeKeychain()
        try await keychain.store(token, for: key)
        keychain.setAbsent(account: key.account)

        let read = try await keychain.read(key)
        #expect(read == nil)
    }

    /// The distinction the store layer depends on: a read FAULT (locked device, missing
    /// entitlement) must throw rather than reading as an absence, so callers never prune a
    /// persisted record on the strength of a failed read.
    @Test("a programmed read fault throws instead of reading as absent")
    func readFaultThrows() async {
        struct ReadFault: Error {}
        let keychain = FakeKeychain()
        keychain.setReadError(account: key.account, error: ReadFault())

        await #expect(throws: ReadFault.self) {
            _ = try await keychain.read(key)
        }
    }

    @Test("delete removes the value and records the account")
    func delete() async throws {
        let keychain = FakeKeychain()
        try await keychain.store(token, for: key)
        try await keychain.delete(key)

        let read = try await keychain.read(key)
        #expect(read == nil)
        #expect(keychain.deleteCalls == [key.account])
    }

    @Test("storing twice overwrites, matching the real keychain's update-on-add")
    func storeOverwrites() async throws {
        let keychain = FakeKeychain()
        try await keychain.store(token, for: key)
        try await keychain.store(Token(access: "new", refresh: "new"), for: key)

        let read = try await keychain.read(key)
        #expect(read?.access == "new")
        #expect(keychain.storeCalls.count == 2)
    }

    /// Behaviour is keyed by ACCOUNT, so two keys of the same shape stay independent — the
    /// multi-server store relies on exactly that.
    @Test("accounts are independent of each other")
    func accountsAreIndependent() async throws {
        let keychain = FakeKeychain()
        let other = KeychainKey<Token>(account: "server-2")

        try await keychain.store(token, for: key)
        let readOther = try await keychain.read(other)
        #expect(readOther == nil)

        try await keychain.delete(key)
        keychain.setAbsent(account: other.account)
        #expect(keychain.deleteCalls == [key.account], "deleting one account must not touch another")
    }

    /// The programmable seed path encodes through the same JSON as `store`, so a seeded value and
    /// a stored one are indistinguishable to a reader.
    @Test("a seeded value reads back like a stored one")
    func seededValueMatchesStored() async throws {
        let keychain = FakeKeychain()
        try keychain.setValue(token, for: key)

        let read = try await keychain.read(key)
        #expect(read == token)
        #expect(keychain.storeCalls.isEmpty, "seeding is not a store call")
    }
}

@Suite("KeychainKey")
struct KeychainKeyTests {
    /// The phantom `Value` is a compile-time guard only — at runtime the account string is the
    /// whole identity, which is what lets the fake and the real store key on it alike.
    @Test("identity is the account string")
    func identityIsTheAccount() {
        #expect(KeychainKey<String>(account: "a") == KeychainKey<String>(account: "a"))
        #expect(KeychainKey<String>(account: "a") != KeychainKey<String>(account: "b"))
        #expect(KeychainKey<String>(account: "a").account == "a")
    }
}
