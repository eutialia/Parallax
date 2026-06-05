import ParallaxJellyfin

extension CollectionType {
    /// SF Symbol for a Jellyfin library, keyed off its `collectionType`. The single source
    /// of truth shared by the sidebar's library tabs (`RootTabView`) and the Library-list
    /// cards (`JellyfinLibraryListView`) so the two can't drift apart.
    ///
    /// Outline (non-filled) variants, per Apple's tab-bar / sidebar convention — the system
    /// fills the selected sidebar row itself, and a frosted card chip reads cleaner outlined.
    /// Jellyfin gives no icon field, so the mapping is by media domain: pick the SF Symbol
    /// Apple uses for that content type (film / tv / music / books / photos), falling back to
    /// the generic stacked-rectangles "library" glyph for anything unrecognised.
    var symbolName: String {
        switch self {
        case .movies: return "film"
        case .tvShows: return "tv"
        case .other(let raw):
            let kind = raw.lowercased()
            if kind.contains("music") { return "music.note" }
            if kind.contains("book") { return "books.vertical" }
            if kind.contains("photo") || kind.contains("home") { return "photo" }
            return "rectangle.stack"
        }
    }
}
