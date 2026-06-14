import ParallaxCore

/// A source-tagged library for the merged library list. Tagging happens at the
/// app boundary — `MediaCollection` stays source-agnostic.
struct LibraryEntry: Identifiable, Hashable {
    let source: MediaSourceID
    let collection: MediaCollection
    var id: LibraryRef { LibraryRef(source: source, collection: collection.id) }
}
