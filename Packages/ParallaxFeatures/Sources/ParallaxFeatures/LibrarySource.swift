import Foundation
import ParallaxFileBrowse
import ParallaxJellyfin
import ParallaxCore

// MARK: - Library source

public nonisolated enum LibrarySource: Hashable, Sendable {
    case jellyfin(Session)
    case smb(SMBServerRef)

    public var displayName: String {
        switch self {
        case .jellyfin(let session): return session.serverName
        // TODO: a friendlier label could come from a stored display name later.
        case .smb(let ref): return ref.data.host
        }
    }

    /// Which band of the library list this source's section sits in: Jellyfin servers first, then
    /// SMB shares. Sources within a band keep the order the user added them.
    ///
    /// Pure add order was the first cut and it read wrong on a real config: an SMB share added
    /// before the Jellyfin server outranked it, putting a metadata-less file wall above the app's
    /// primary source. Add order is also a weaker signal than it looks — `ServerStore.add` replaces
    /// a row in place for a re-signed-in server (id is deterministic) but a removed-then-re-added
    /// server APPENDS, so "first in the array" doesn't reliably mean "adopted first".
    ///
    /// Ranking by kind instead matches the app's own source hierarchy (Jellyfin is v1's primary,
    /// SMB the auxiliary browse surface) and is deterministic with no new UI or stored order.
    var sectionRank: Int {
        switch self {
        case .jellyfin: return 0
        case .smb: return 1
        }
    }
}

// Navigation value used by every NavigationLink that drills into a
// detail screen. Same shape regardless of source — the destination
// view model decides what to load. Defined here because LibrarySource
// is the natural sibling, and Task 17 (HomeView) is the first user.
public nonisolated enum ItemNavigation: Hashable, Sendable {
    case movie(ItemID, LibrarySource)
    case series(ItemID, LibrarySource)
}

nonisolated extension LibrarySource {
    public var sourceID: MediaSourceID {
        switch self {
        case .jellyfin(let session): .jellyfin(session.id)
        case .smb(let ref): .smb(ref.id)
        }
    }
}
