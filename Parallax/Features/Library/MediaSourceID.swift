import ParallaxJellyfin

/// Stable identity of an active media source. Derived from the source's natural
/// key (Jellyfin server id or SMB server id), never a fresh UUID, so identity
/// survives server switches.
enum MediaSourceID: Hashable {
    case jellyfin(ServerID)
    case smb(ServerID)

    /// The `ServerStore` row this source belongs to. Server ids are unique across kinds (SMB ids
    /// are minted as `smb-<host>`), so this is the key everything server-scoped and persisted —
    /// hidden libraries, Keychain slots, snapshot files — is filed under.
    var serverID: ServerID {
        switch self {
        case .jellyfin(let id), .smb(let id): id
        }
    }
}

extension LibrarySource {
    var sourceID: MediaSourceID {
        switch self {
        case .jellyfin(let session): .jellyfin(session.id)
        case .smb(let ref): .smb(ref.id)
        }
    }
}
