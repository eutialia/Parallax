import ParallaxCore
import ParallaxJellyfin

/// An `Item` tagged with the source it came from. Tagging happens at the app boundary — the
/// ParallaxCore models stay source-agnostic — exactly as `LibraryEntry` does for collections.
///
/// This exists because the AGGREGATED surfaces (Home, Search, Favorites) put items from several
/// servers on one screen, which breaks the assumption every tile used to make: that "the session"
/// is a property of the SCREEN. It isn't any more. A Continue Watching shelf holding an item from
/// server B would otherwise build its poster URL against server A's host and bearer token — a 404
/// at best, and the wrong artwork if two servers happen to mint the same item id (Jellyfin derives
/// item GUIDs deterministically from the media path, so mirrored libraries genuinely can collide).
///
/// Library grids stay single-server and keep passing a plain `Item` + one screen-level `Session`;
/// only the surfaces that actually mix sources pay for this.
/// One item's identity on an aggregated surface: which server it came from, and its id there.
///
/// Its own type rather than reusing `LibraryRef`, which pairs a source with a `CollectionID` — an
/// `ItemID` squeezed into that slot happens to work (both wrap a String) while quietly erasing the
/// distinction between "a library on server A" and "an item on server A". Keeping them apart is
/// what stops an item identity being handed to something expecting a library.
struct SourcedItemID: Hashable {
    let source: MediaSourceID
    let item: ItemID
}

struct SourcedItem: Identifiable, Hashable {
    let item: Item
    let source: LibrarySource

    /// Compound identity. The `ItemID` alone is NOT unique across servers, so a `ForEach` keyed on
    /// it would collide (SwiftUI drops duplicate ids, silently losing a tile) the moment two
    /// servers hold the same title with a path-derived id.
    var id: SourcedItemID { SourcedItemID(source: source.sourceID, item: item.id) }

    /// The Jellyfin session backing this item, when it came from a Jellyfin server. Home is
    /// Jellyfin-only today (SMB has no watch-progress feed), so its tiles unwrap this; Search will
    /// carry SMB hits once a file-source provider exists.
    var jellyfinSession: Session? {
        if case .jellyfin(let session) = source { return session }
        return nil
    }
}

/// A hero entry tagged with its source — the hero carousel mixes servers for the same reason the
/// shelves do, and its artwork/play-target both need the originating server.
struct SourcedHeroEntry: Identifiable, Hashable {
    let entry: HomeHeroFeedEntry
    let source: LibrarySource

    var id: SourcedItemID {
        SourcedItemID(source: source.sourceID, item: entry.id)
    }

    var jellyfinSession: Session? {
        if case .jellyfin(let session) = source { return session }
        return nil
    }
}

extension Array where Element == SourcedItem {
    /// Merge several servers' progress-ordered lists into one, newest play first.
    ///
    /// Each Jellyfin server returns Continue Watching already sorted by play date, but sorted
    /// *within itself* — concatenating two such lists yields "all of server A, then all of server
    /// B", which reads as stale-then-fresh rather than a single timeline. `lastPlayedDate` is the
    /// only shared key that can interleave them; items missing it (never played, or a source that
    /// doesn't track it) sort last, keeping their relative order via the index tie-break so the
    /// result is stable rather than arbitrary.
    static func mergedByLastPlayed(_ lists: [[SourcedItem]]) -> [SourcedItem] {
        lists
            .flatMap { $0 }
            .enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.item.userData.lastPlayedDate, rhs.element.item.userData.lastPlayedDate) {
                case let (l?, r?): return l == r ? lhs.offset < rhs.offset : l > r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }
}

extension Array {
    /// Interleave several servers' lists round-robin, preserving each server's own ordering.
    ///
    /// Used where the lists carry no comparable key — Next Up is server-ranked with no shared
    /// score, hero is a curated recency mix, and search relevance is per-server. Taking the first
    /// from each server, then the second from each, gives every server presence near the top
    /// instead of burying the second server below the whole of the first, and it's stable and
    /// explicable, unlike inventing a cross-server relevance number the data can't support.
    ///
    /// Unconstrained in `Element` because the same rule has to hold for the hero feed
    /// (`SourcedHeroEntry`) as for the item shelves — it was written twice before, once per type,
    /// which is exactly how the two would have drifted.
    static func interleaved(_ lists: [[Element]]) -> [Element] {
        let depth = lists.map(\.count).max() ?? 0
        return (0 ..< depth).flatMap { index in
            lists.compactMap { index < $0.count ? $0[index] : nil }
        }
    }
}
