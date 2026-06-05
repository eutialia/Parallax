import Foundation

public struct UserSnapshot: Sendable, Hashable, Codable {
    public let id: String
    public let name: String
    /// Tag of the user's Jellyfin profile image, or nil when they have none. Drives the
    /// account avatar (`/Users/{id}/Images/Primary`). Defaulted + optional so older
    /// persisted sessions (which never stored it) decode as nil via `decodeIfPresent`.
    public let primaryImageTag: String?
    public let serverLastUpdatedAt: Date?

    public init(id: String, name: String, primaryImageTag: String? = nil, serverLastUpdatedAt: Date?) {
        self.id = id
        self.name = name
        self.primaryImageTag = primaryImageTag
        self.serverLastUpdatedAt = serverLastUpdatedAt
    }
}
