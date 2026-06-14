import Foundation

/// A live, authenticated Jellyfin session: a persisted server (always of the
/// `.jellyfin` kind) plus its in-memory bearer token. SMB servers persist as
/// `PersistedServer` too but never become a `Session` — they have no Jellyfin
/// API surface to drive.
public struct Session: Sendable, Hashable, Identifiable {
    public let persisted: PersistedServer
    public let data: JellyfinServerData
    public let accessToken: String

    /// Builds a session from a `.jellyfin` `PersistedServer`. Returns `nil` for
    /// any other kind — only Jellyfin servers have a session.
    public init?(persisted: PersistedServer, accessToken: String) {
        guard case .jellyfin(let data) = persisted.kind else { return nil }
        self.persisted = persisted
        self.data = data
        self.accessToken = accessToken
    }

    public init(id: ServerID, data: JellyfinServerData, accessToken: String) {
        self.persisted = PersistedServer(id: id, kind: .jellyfin(data))
        self.data = data
        self.accessToken = accessToken
    }

    public var id: ServerID { persisted.id }
    public var serverURL: URL { data.serverURL }
    public var serverName: String { data.serverName }
    public var user: UserSnapshot { data.user }
}
