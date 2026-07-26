import Foundation
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxCore

@Suite("Movie artwork")
struct MovieArtworkTests {
    private let primary = ImageTag(rawValue: "movie-primary")
    private let backdrops = [ImageTag(rawValue: "bd-0"), ImageTag(rawValue: "bd-1")]
    private let logo = ImageTag(rawValue: "movie-logo")
    private let thumb = ImageTag(rawValue: "movie-thumb")

    private func movie(blurHashes: [ImageTag: String] = [:]) -> Movie {
        LibraryFixtures.movie(
            primaryTag: primary, backdropTags: backdrops, logoTag: logo, thumbTag: thumb,
            blurHashes: blurHashes
        )
    }

    @Test("each supported kind resolves to its own tag")
    func kindsMapToTheirTags() throws {
        let movie = movie()
        #expect(movie.imageRef(.primary)?.tag == primary)
        #expect(movie.imageRef(.logo)?.tag == logo)
        #expect(movie.imageRef(.thumb)?.tag == thumb)
        #expect(movie.imageRef(.backdrop(index: 0))?.tag == backdrops[0])
        #expect(movie.imageRef(.backdrop(index: 1))?.tag == backdrops[1])
    }

    /// Backdrops are INDEXED, so an out-of-range index must return nil rather than trapping on
    /// the array subscript — hero carousels page past the end routinely.
    @Test("an out-of-range backdrop index is nil, never a crash", arguments: [2, 99, -1])
    func backdropIndexIsBoundsChecked(index: Int) {
        #expect(movie().imageRef(.backdrop(index: index)) == nil)
    }

    @Test("kinds a movie never carries are nil", arguments: [ImageKind.banner, .art, .disc])
    func unsupportedKindsAreNil(kind: ImageKind) {
        #expect(movie().imageRef(kind) == nil)
    }

    @Test("a missing tag yields no ref for that kind")
    func missingTagYieldsNil() {
        let bare = LibraryFixtures.movie(
            primaryTag: nil, backdropTags: [], logoTag: nil, thumbTag: nil
        )
        #expect(bare.imageRef(.primary) == nil)
        #expect(bare.imageRef(.logo) == nil)
        #expect(bare.imageRef(.thumb) == nil)
        #expect(bare.imageRef(.backdrop(index: 0)) == nil)
    }

    /// Hashes are keyed by TAG, not by kind, which is what makes indexed backdrops work: each
    /// backdrop tag maps to its own blur.
    @Test("each ref carries the BlurHash registered for its own tag")
    func blurHashIsKeyedByTag() throws {
        let movie = movie(blurHashes: [primary: "primary-hash", backdrops[1]: "backdrop-1-hash"])
        #expect(movie.imageRef(.primary)?.blurHash == "primary-hash")
        #expect(movie.imageRef(.backdrop(index: 1))?.blurHash == "backdrop-1-hash")
        #expect(movie.imageRef(.backdrop(index: 0))?.blurHash == nil)
    }

    @Test("the ref points back at the owning item")
    func refCarriesTheItemID() throws {
        let movie = LibraryFixtures.movie(id: "tt1375666")
        #expect(movie.imageRef(.primary)?.itemID == ItemID(rawValue: "tt1375666"))
    }

    @Test("withUserData keeps the artwork tags and hashes")
    func withUserDataPreservesArtwork() {
        let original = movie(blurHashes: [primary: "hash"])
        let updated = original.withUserData(LibraryFixtures.userData(played: true))
        #expect(updated.blurHashes == original.blurHashes)
        #expect(updated.primaryTag == original.primaryTag)
        #expect(updated.backdropTags == original.backdropTags)
        #expect(updated.withUserData(original.userData) == original)
    }
}

@Suite("Series artwork")
struct SeriesArtworkTests {
    private let primary = ImageTag(rawValue: "series-primary")
    private let backdrops = [ImageTag(rawValue: "s-bd-0")]
    private let banner = ImageTag(rawValue: "series-banner")

    private func series(blurHashes: [ImageTag: String] = [:]) -> Series {
        LibraryFixtures.series(
            primaryTag: primary, backdropTags: backdrops,
            logoTag: ImageTag(rawValue: "series-logo"), thumbTag: ImageTag(rawValue: "series-thumb"),
            bannerTag: banner, blurHashes: blurHashes
        )
    }

    /// A series is the one model that carries a banner — that's the difference from `Movie`.
    @Test("a series resolves the banner kind a movie cannot")
    func bannerIsSeriesOnly() throws {
        #expect(series().imageRef(.banner)?.tag == banner)
        #expect(LibraryFixtures.movie().imageRef(.banner) == nil)
    }

    @Test("each supported kind resolves to its own tag")
    func kindsMapToTheirTags() throws {
        let series = series()
        #expect(series.imageRef(.primary)?.tag == primary)
        #expect(series.imageRef(.backdrop(index: 0))?.tag == backdrops[0])
        #expect(series.imageRef(.logo)?.tag == ImageTag(rawValue: "series-logo"))
        #expect(series.imageRef(.thumb)?.tag == ImageTag(rawValue: "series-thumb"))
    }

    @Test("an out-of-range backdrop index is nil", arguments: [1, 99, -1])
    func backdropIndexIsBoundsChecked(index: Int) {
        #expect(series().imageRef(.backdrop(index: index)) == nil)
    }

    @Test("kinds a series never carries are nil", arguments: [ImageKind.art, .disc])
    func unsupportedKindsAreNil(kind: ImageKind) {
        #expect(series().imageRef(kind) == nil)
    }

    @Test("each ref carries the BlurHash registered for its own tag")
    func blurHashIsKeyedByTag() throws {
        let series = series(blurHashes: [banner: "banner-hash"])
        #expect(series.imageRef(.banner)?.blurHash == "banner-hash")
        #expect(series.imageRef(.primary)?.blurHash == nil)
    }

    @Test("withUserData keeps the artwork tags and hashes")
    func withUserDataPreservesArtwork() {
        let original = series(blurHashes: [primary: "hash"])
        let updated = original.withUserData(LibraryFixtures.userData(isFavorite: true))
        #expect(updated.blurHashes == original.blurHashes)
        #expect(updated.bannerTag == original.bannerTag)
        #expect(updated.withUserData(original.userData) == original)
    }
}

@Suite("Season artwork")
struct SeasonArtworkTests {
    private let primary = ImageTag(rawValue: "season-primary")
    private let thumb = ImageTag(rawValue: "season-thumb")

    /// A season folder only has a poster and a thumb — everything else belongs to its series.
    @Test("only primary and thumb resolve")
    func supportedKinds() throws {
        let season = LibraryFixtures.season(
            primaryTag: primary, thumbTag: thumb, blurHashes: [primary: "poster-hash"]
        )
        #expect(season.imageRef(.primary)?.tag == primary)
        #expect(season.imageRef(.primary)?.blurHash == "poster-hash")
        #expect(season.imageRef(.thumb)?.tag == thumb)
    }

    @Test("kinds a season never carries are nil",
          arguments: [ImageKind.backdrop(index: 0), .logo, .banner, .art, .disc])
    func unsupportedKindsAreNil(kind: ImageKind) {
        #expect(LibraryFixtures.season(primaryTag: primary, thumbTag: thumb).imageRef(kind) == nil)
    }

    @Test("a missing tag yields no ref")
    func missingTagYieldsNil() {
        let bare = LibraryFixtures.season(primaryTag: nil, thumbTag: nil)
        #expect(bare.imageRef(.primary) == nil)
        #expect(bare.imageRef(.thumb) == nil)
    }
}

@Suite("MediaCollection")
struct MediaCollectionTests {
    /// A collection's id is a `CollectionID`, but artwork URLs are built from `ItemID` — the
    /// bridge is deliberate, and losing it would point every library tile at the wrong item.
    @Test("the primary ref bridges the collection id into an item id")
    func primaryRefBridgesTheID() throws {
        let collection = LibraryFixtures.collection(id: "lib-42", primaryTag: ImageTag(rawValue: "t"))
        let ref = try #require(collection.imageRef(.primary))
        #expect(ref.itemID == ItemID(rawValue: "lib-42"))
        #expect(ref.tag == ImageTag(rawValue: "t"))
    }

    @Test("the primary ref carries its tag's BlurHash")
    func primaryRefCarriesBlurHash() throws {
        let tag = ImageTag(rawValue: "t")
        let collection = LibraryFixtures.collection(primaryTag: tag, blurHashes: [tag: "hash"])
        #expect(collection.imageRef(.primary)?.blurHash == "hash")
    }

    @Test("no primary tag means no ref")
    func noPrimaryTag() {
        #expect(LibraryFixtures.collection(primaryTag: nil).imageRef(.primary) == nil)
    }

    @Test("a collection carries no artwork but its poster",
          arguments: [ImageKind.backdrop(index: 0), .logo, .thumb, .banner, .art, .disc])
    func onlyPrimaryResolves(kind: ImageKind) {
        #expect(LibraryFixtures.collection().imageRef(kind) == nil)
    }
}

@Suite("ImageKind")
struct ImageKindTests {
    /// These segments go straight into `/Items/{id}/Images/{segment}` — they are the wire
    /// contract, not display strings.
    @Test("each kind maps to its Jellyfin path segment", arguments: [
        (ImageKind.primary, "Primary"),
        (.backdrop(index: 0), "Backdrop"),
        (.backdrop(index: 7), "Backdrop"),   // the index is a separate URL component
        (.logo, "Logo"),
        (.thumb, "Thumb"),
        (.banner, "Banner"),
        (.art, "Art"),
        (.disc, "Disc"),
    ])
    func pathSegment(kind: ImageKind, expected: String) {
        #expect(kind.pathSegment == expected)
    }

    @Test("backdrops at different indices are distinct kinds")
    func backdropIndexIsPartOfIdentity() {
        #expect(ImageKind.backdrop(index: 0) != ImageKind.backdrop(index: 1))
        #expect(ImageKind.backdrop(index: 0) == ImageKind.backdrop(index: 0))
    }
}

@Suite("ImageRef")
struct ImageRefTests {
    /// SMB/local refs have no server-side BlurHash, so the parameter defaults away.
    @Test("the BlurHash is optional and defaults to absent")
    func blurHashDefaultsToNil() {
        let ref = ImageRef(itemID: ItemID(rawValue: "i"), kind: .primary, tag: ImageTag(rawValue: "t"))
        #expect(ref.blurHash == nil)
    }

    /// Two refs to the same item differing only by kind must not collide — they key separate
    /// cache entries.
    @Test("kind and tag both participate in identity")
    func identity() {
        let base = LibraryFixtures.imageRef(kind: .primary, tag: "t")
        #expect(base != LibraryFixtures.imageRef(kind: .thumb, tag: "t"))
        #expect(base != LibraryFixtures.imageRef(kind: .primary, tag: "other"))
        #expect(base == LibraryFixtures.imageRef(kind: .primary, tag: "t"))
    }
}
