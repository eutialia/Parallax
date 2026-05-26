import Foundation

public struct KeychainKey: Sendable, Hashable {
    public let account: String

    public init(account: String) {
        self.account = account
    }
}
