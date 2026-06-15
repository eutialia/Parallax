import ParallaxJellyfin

/// Stable identity of an active media source. Derived from the source's natural
/// key (Jellyfin server id or SMB server id), never a fresh UUID, so identity
/// survives server switches.
enum MediaSourceID: Hashable {
    case jellyfin(ServerID)
    case smb(ServerID)
}

extension LibrarySource {
    var sourceID: MediaSourceID {
        switch self {
        case .jellyfin(let session): .jellyfin(session.id)
        case .smb(let ref): .smb(ref.id)
        }
    }
}
