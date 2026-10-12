import ParallaxJellyfin
import ParallaxCore
import ParallaxFeatures

extension CollectionType {
    /// SF Symbol for a Jellyfin library, keyed off its `collectionType`. The single source
    /// of truth shared by the sidebar's library tabs (`RootTabView`) and the Library-list
    /// cards (`LibraryListView`) so the two can't drift apart.
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
        // A mixed library holds both, so neither film nor tv is honest — the generic library
        // glyph is.
        case .mixed: return "rectangle.stack"
        case .other(let raw):
            let kind = raw.lowercased()
            if kind.contains("music") { return "music.note" }
            if kind.contains("book") { return "books.vertical" }
            if kind.contains("photo") || kind.contains("home") { return "photo" }
            return "rectangle.stack"
        }
    }
}

extension LibraryEntry {
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
