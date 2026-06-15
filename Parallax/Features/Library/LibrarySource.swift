import Foundation
import ParallaxJellyfin
import ParallaxCore

// MARK: - SMB source identity

/// Identity + connection metadata for a configured SMB source. Mirrors how
/// `.jellyfin(Session)` carries everything a Jellyfin source needs — minus the
/// password, which is read from the Keychain (slot `token-<id>`) at connect time.
struct SMBServerRef: Hashable {
    let id: ServerID
    let data: SMBServerData
}

// MARK: - Library source

enum LibrarySource: Hashable {
    case jellyfin(Session)
    case smb(SMBServerRef)

    var displayName: String {
        switch self {
        case .jellyfin(let session): return session.serverName
        // TODO: a friendlier label could come from a stored display name later.
        case .smb(let ref): return ref.data.host
        }
    }
}

// Navigation value used by every NavigationLink that drills into a
// detail screen. Same shape regardless of source — the destination
// view model decides what to load. Defined here because LibrarySource
// is the natural sibling, and Task 17 (HomeView) is the first user.
enum ItemNavigation: Hashable {
    case movie(ItemID, LibrarySource)
    case series(ItemID, LibrarySource)
}
