import Foundation

public struct UserSnapshot: Sendable, Hashable, Codable {
    public let id: String
    public let name: String
    public let serverLastUpdatedAt: Date?

    public init(id: String, name: String, serverLastUpdatedAt: Date?) {
        self.id = id
        self.name = name
        self.serverLastUpdatedAt = serverLastUpdatedAt
    }
}
