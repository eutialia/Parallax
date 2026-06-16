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

    /// Tile shape for this source's library grid: SMB items are video frame-grabs that read as 16:9
    /// landscape; Jellyfin items carry 2:3 portrait posters. Drives BOTH the tile aspect ratio and
    /// the (sparser) landscape column count in `LibraryGridView`. The switch is exhaustive on
    /// purpose — a new source must declare its shape here, or it won't compile, instead of silently
    /// defaulting to a poster box that overflows a wide thumbnail and steals the cell's taps.
    var usesLandscapeTiles: Bool {
        switch self {
        case .jellyfin: false
        case .smb: true
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
