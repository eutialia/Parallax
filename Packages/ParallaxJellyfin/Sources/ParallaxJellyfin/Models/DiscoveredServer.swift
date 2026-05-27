import Foundation

public struct DiscoveredServer: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let address: URL

    public init(id: String, name: String, address: URL) {
        self.id = id
        self.name = name
        self.address = address
    }
}
