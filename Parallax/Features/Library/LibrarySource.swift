import Foundation
import ParallaxJellyfin

// One case in v1. v2 adds .files(FileSource) and others.
enum LibrarySource: Hashable {
    case jellyfin(Session)

    var displayName: String {
        switch self {
        case .jellyfin(let session): return session.serverName
        }
    }
}

// Navigation value used by every NavigationLink that drills into a
// detail screen. Same shape regardless of source — the destination
// view model decides what to load. Defined here because LibrarySource
// is the natural sibling, and Task 17 (HomeView) is the first user.
enum ItemNavigation: Hashable {
    case movie(ItemID, Session)
    case series(ItemID, Session)
    case season(ItemID, Session)
    case episode(ItemID, Session)
}
