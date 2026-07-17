import Testing
import Foundation
import ParallaxCore

// Hosted (entitled) coverage for the REAL `Keychain` actor. The package-level
// KeychainTests suite self-skips on unentitled SwiftPM test hosts, so this
// app-hosted run — which inherits the app's keychain access — is where the
// SecItem paths actually execute. Kept to the seams a fake can't reproduce:
// the update-vs-add fallback and cross-instance persistence.
@Suite("Keychain (entitled host)")
struct KeychainIntegrationTests {
    private static let service = "com.lhdev.parallax.hosted-tests"

    @Test("round-trip, overwrite, and delete against the real keychain")
    func roundTrip() async throws {
        let keychain = Keychain(service: Self.service)
        let key = KeychainKey<String>(account: "integration-\(UUID().uuidString)")

        try await keychain.store("first", for: key)
        try await keychain.store("second", for: key) // SecItemUpdate path
        let updated = try await keychain.read(key)
        #expect(updated == "second")

        // A fresh actor instance sees the same item — persistence is real
        // SecItem state, not per-instance memory.
        let secondInstance = Keychain(service: Self.service)
        let reread = try await secondInstance.read(key)
        #expect(reread == "second")

        try await keychain.delete(key)
        let afterDelete = try await keychain.read(key)
        #expect(afterDelete == nil)
    }
}
