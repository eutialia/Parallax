import Foundation
import Security

/// Detects whether the current test host can use the real Keychain.
///
/// SwiftPM package tests run in an unentitled host process, where every data-protection
/// `SecItem*` call fails with `errSecMissingEntitlement (-34018)`. The probe asks the same
/// keychain `Keychain` uses. Suites that exercise the real `Keychain` gate themselves on this
/// probe via `.enabled(if:)` so unentitled hosts report skips instead of false failures.
public enum KeychainEntitlementProbe {
    /// True when a round-trip `SecItemAdd` succeeds in this process.
    /// Cached: the entitlement cannot change mid-run.
    public static let hasKeychainAccess: Bool = {
        let service = "com.lhdev.parallax.tests.entitlement-probe"
        let account = UUID().uuidString
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecValueData as String: Data("probe".utf8),
        ]
        guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else {
            return false
        }
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        return true
    }()
}
