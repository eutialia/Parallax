import Foundation

// The discriminated shape `ServerStore` writes to `UserDefaults`. A persisted
// server is one of several source kinds; the secret (Jellyfin bearer token or
// SMB password) is never stored here — it lives in the Keychain, keyed by the
// server's `id`.

/// Jellyfin-specific persisted metadata. Carries exactly the fields the legacy
/// flat `PersistedSession` held, so a v1 user migrates with no data loss.
public struct JellyfinServerData: Sendable, Hashable, Codable {
    public let serverURL: URL
    public let serverName: String
    public let user: UserSnapshot

    public init(serverURL: URL, serverName: String, user: UserSnapshot) {
        self.serverURL = serverURL
        self.serverName = serverName
        self.user = user
    }
}

/// SMB-specific persisted metadata: one record per *server* (host). The selected
/// `shares` are the libraries; each share's root is browsed in-app. The password is
/// NOT held here — it lives in the Keychain under the server's id.
public struct SMBServerData: Sendable, Hashable, Codable {
    public let host: String
    public let username: String
    public let domain: String
    public let shares: [String]

    public init(host: String, username: String, domain: String, shares: [String]) {
        self.host = host
        self.username = username
        self.domain = domain
        self.shares = shares
    }
}

/// Discriminated source kind for a persisted server. New cases are additive:
/// only `ServerStore` switches over this, so adding a kind never ripples into
/// unrelated exhaustive switches elsewhere.
public enum PersistedServerKind: Sendable, Hashable, Codable {
    case jellyfin(JellyfinServerData)
    case smb(SMBServerData)
}

/// What `ServerStore` writes to `UserDefaults` per configured server.
public struct PersistedServer: Sendable, Hashable, Codable, Identifiable {
    public let id: ServerID
    public let kind: PersistedServerKind

    public init(id: ServerID, kind: PersistedServerKind) {
        self.id = id
        self.kind = kind
    }
}
