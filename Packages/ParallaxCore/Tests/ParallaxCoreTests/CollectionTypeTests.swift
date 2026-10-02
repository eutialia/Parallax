import Testing
import ParallaxCore

/// `isBrowsable` decides whether a Jellyfin library appears at all, on every platform at once —
/// so its edges are worth pinning. It exists because the rule used to be a private switch inside
/// one view, which left the iPad sidebar and tvOS root listing collections the iPhone list hid.
@Suite("CollectionType.isBrowsable")
struct CollectionTypeTests {
    @Test("Movie and show libraries are browsable")
    func typedVideoLibrariesAreBrowsable() {
        #expect(CollectionType.movies.isBrowsable)
        #expect(CollectionType.tvShows.isBrowsable)
    }

    /// The regression this case exists for: Jellyfin reports NO `collectionType` for a
    /// mixed-content library, and folding that into `.other` made those libraries vanish from the
    /// sidebar, the iPhone list, and the tvOS root — content the user definitely has, silently
    /// unreachable. They browse fine: the grid queries movies and series by parent id.
    @Test("An untyped (mixed-content) library is browsable")
    func mixedLibrariesAreBrowsable() {
        #expect(CollectionType.mixed.isBrowsable)
    }

    @Test(
        "Libraries with no browse surface here are excluded",
        arguments: ["music", "musicvideos", "books", "photos", "livetv", "playlists"]
    )
    func unsupportedLibrariesAreExcluded(raw: String) {
        #expect(CollectionType.other(raw).isBrowsable == false)
    }
}
