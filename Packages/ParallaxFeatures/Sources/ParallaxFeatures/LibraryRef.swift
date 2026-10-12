import ParallaxCore

/// Tab/selection identity of a library, disambiguated by source so two sources
/// cannot collide on a shared CollectionID rawValue.
public nonisolated struct LibraryRef: Hashable, Sendable {
    public let source: MediaSourceID
    public let collection: CollectionID

    public init(source: MediaSourceID, collection: CollectionID) {
        self.source = source
        self.collection = collection
    }
}
