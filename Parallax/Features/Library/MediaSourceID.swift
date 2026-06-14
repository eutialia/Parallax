import ParallaxJellyfin

/// Stable identity of an active media source. Derived from the source's natural
/// key (Jellyfin server id), never a fresh UUID, so identity survives server
/// switches. Phase 2 adds `.smb`.
enum MediaSourceID: Hashable {
    case jellyfin(ServerID)
}

extension LibrarySource {
    var sourceID: MediaSourceID {
        switch self {
        case .jellyfin(let session): .jellyfin(session.id)
        }
    }
}
