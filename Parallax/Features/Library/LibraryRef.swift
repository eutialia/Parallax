import ParallaxCore

/// Tab/selection identity of a library, disambiguated by source so two sources
/// cannot collide on a shared CollectionID rawValue.
struct LibraryRef: Hashable {
    let source: MediaSourceID
    let collection: CollectionID
}
