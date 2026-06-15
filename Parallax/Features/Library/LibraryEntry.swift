import ParallaxCore

/// A source-tagged library for the merged library list. Tagging happens at the
/// app boundary — `MediaCollection` stays source-agnostic. Carries the full
/// `LibrarySource` so the grid can build its repo and dispatch taps (Jellyfin
/// detail push vs. SMB direct-play); identity still derives from the stable
/// `.sourceID`, so tab identity is unchanged for Jellyfin.
struct LibraryEntry: Identifiable {
    let source: LibrarySource
    let collection: MediaCollection
    var id: LibraryRef { LibraryRef(source: source.sourceID, collection: collection.id) }
}
