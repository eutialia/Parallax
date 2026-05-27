import Foundation

// What `ServerStore` writes to `UserDefaults`. Deliberately excludes the
// access token — tokens belong in the Keychain, never in plist storage.
public struct PersistedSession: Sendable, Hashable, Codable, Identifiable {
    public let id: ServerID
    public let serverURL: URL
    public let serverName: String
    public let user: UserSnapshot

    public init(id: ServerID, serverURL: URL, serverName: String, user: UserSnapshot) {
        self.id = id
        self.serverURL = serverURL
        self.serverName = serverName
        self.user = user
    }
}
