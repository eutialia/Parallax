import Foundation

// Phantom-typed key: the `Value` parameter prevents two call sites from
// storing different shapes under the same account string by accident.
// Two `KeychainKey<A>` and `KeychainKey<B>` with the same account are
// different types and won't satisfy each other's signature at the API boundary.
public struct KeychainKey<Value: Codable & Sendable>: Sendable, Hashable {
    public let account: String

    public init(account: String) {
        self.account = account
    }
}
