import ParallaxCore

/// A source-tagged library for the merged library list. Tagging happens at the
/// app boundary — `MediaCollection` stays source-agnostic. Carries the full
/// `LibrarySource` so the grid can build its repo and dispatch taps (Jellyfin
/// detail push vs. SMB direct-play); identity still derives from the stable
/// `.sourceID`, so tab identity is unchanged for Jellyfin.
///
/// `Hashable` so it doubles as a `NavigationLink` value: the iPhone library
/// card-list pushes the SMB grid by entry. Synthesized over `source` +
/// `collection` (both `Hashable`); the computed `id` isn't a stored property
/// and so doesn't enter the hash.
struct LibraryEntry: Identifiable, Hashable {
    let source: LibrarySource
    let collection: MediaCollection
    var id: LibraryRef { LibraryRef(source: source.sourceID, collection: collection.id) }

    /// SF Symbol for this entry's sidebar tab (iPad `RootTabView` / tvOS `FocusRootView`): a
    /// network-share glyph for an SMB share, the media-type glyph for a Jellyfin collection.
    /// `externaldrive.badge.wifi` reads as a networked drive — the clearest "network share" of the
    /// candidates (rendered side by side in RootTabView's preview; `network`'s globe says "web" and
    /// plain `externaldrive` says "local disk"), and the same glyph the SMB browse breadcrumb +
    /// share picker already use, so the SMB visual language stays consistent. Outline (non-filled)
    /// per Apple's sidebar convention — the system fills the selected row.
    var tabSymbolName: String {
        switch source {
        case .smb: return "externaldrive.badge.wifi"
        case .jellyfin: return collection.collectionType.symbolName
        }
    }
}

extension AppTab {
    /// Fall back to `.home` if this tab points at a library collection no longer present in `entries`
    /// — the stale-tab snap both platform roots (`RootTabView`, `FocusRootView`) run after a
    /// non-remounting SMB add/remove rebuilds the merged list (a Jellyfin switch/sign-out instead
    /// resets selection via the `.id(activeServerID)` remount). Shared so the two roots can't drift.
    func snappedIfStale(against entries: [LibraryEntry]) -> AppTab {
        if case .collection(let ref) = self, !entries.contains(where: { $0.id == ref }) {
            return .home
        }
        return self
    }
}
