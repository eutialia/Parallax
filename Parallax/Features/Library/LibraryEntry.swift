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
}
