import ParallaxJellyfin

/// Stable identity of an active media source. Derived from the source's natural
/// key (Jellyfin server id or SMB server id), never a fresh UUID, so identity
/// survives server switches.
public nonisolated enum MediaSourceID: Hashable, Sendable {
    case jellyfin(ServerID)
    case smb(ServerID)

    /// The `ServerStore` row this source belongs to. Server ids are unique across kinds (SMB ids
    /// are minted as `smb-<host>`), so this is the key everything server-scoped and persisted —
    /// hidden libraries, Keychain slots, snapshot files — is filed under.
    public var serverID: ServerID {
        switch self {
        case .jellyfin(let id), .smb(let id): id
        }
    }
}
