import Foundation
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxCore

@Suite("ItemSort")
struct ItemSortTests {
    /// The direction people MEAN when they tap a field name: dates newest-first, titles A→Z,
    /// ratings highest-first. The UI resets to this on every field switch, so "Title" can never
    /// inherit a stale Z→A from a previous "Newest" pick.
    @Test("each field starts in the direction the field name implies", arguments: [
        (ItemSort.Field.title, ItemSort.Direction.ascending),
        (.releaseDate, .descending),
        (.dateAdded, .descending),
        (.communityRating, .descending),
        (.officialRating, .descending),
    ])
    func naturalDirection(field: ItemSort.Field, expected: ItemSort.Direction) {
        #expect(field.naturalDirection == expected)
    }

    /// Every field must answer — a new field added without a natural direction would land in
    /// whatever the switch's default is, which is exactly the stale-direction bug above.
    @Test("every field has a natural direction", arguments: ItemSort.Field.allCases)
    func everyFieldHasANaturalDirection(field: ItemSort.Field) {
        #expect(ItemSort.Direction.allCases.contains(field.naturalDirection))
    }

    /// Title is the ONE ascending field; if a second one appears it should be a deliberate edit.
    @Test("title is the only field that starts ascending")
    func onlyTitleAscends() {
        let ascending = ItemSort.Field.allCases.filter { $0.naturalDirection == .ascending }
        #expect(ascending == [.title])
    }

    @Test("a library opens on newest-first release date")
    func defaultForLibrary() {
        #expect(ItemSort.defaultForLibrary.field == .releaseDate)
        #expect(ItemSort.defaultForLibrary.direction == .descending)
        #expect(ItemSort.defaultForLibrary.direction == ItemSort.Field.releaseDate.naturalDirection,
                "the library default must agree with its field's natural direction")
    }

    @Test("a sort is identified by both field and direction")
    func identity() {
        let ascendingTitle = ItemSort(field: .title, direction: .ascending)
        #expect(ascendingTitle != ItemSort(field: .title, direction: .descending))
        #expect(ascendingTitle != ItemSort(field: .dateAdded, direction: .ascending))
        #expect(ascendingTitle == ItemSort(field: .title, direction: .ascending))
    }
}

@Suite("Page")
struct PageTests
{
    /// The cursor is the ONLY "is there more?" signal the grid has — `items.count < total` can't
    /// carry it, because a filtered page legitimately returns fewer rows than the total.
    @Test("a nil next cursor is what marks the last page")
    func nextCursorMarksTheEnd() {
        let last = Page(items: [1, 2, 3], total: 3, nextCursor: nil)
        let more = Page(items: [1, 2, 3], total: 40, nextCursor: .startIndex(3))

        #expect(last.nextCursor == nil)
        #expect(more.nextCursor == PageCursor.startIndex(3))
    }

    /// An empty page still reports the true total: an over-scrolled fetch must not read as an
    /// empty library.
    @Test("an empty page keeps the collection's real total")
    func emptyPageKeepsTotal() {
        let page = Page<Int>(items: [], total: 120, nextCursor: nil)
        #expect(page.items.isEmpty)
        #expect(page.total == 120)
    }

    @Test("cursors at the same start index are interchangeable")
    func cursorIdentity() {
        #expect(PageCursor.startIndex(50) == PageCursor.startIndex(50))
        #expect(PageCursor.startIndex(50) != PageCursor.startIndex(51))
        #expect(PageCursor.startIndex(50).startIndex == 50)
    }
}

@Suite("SearchResults")
struct SearchResultsTests {
    /// `.empty` is what a cleared or too-short query resolves to, so it must be genuinely empty
    /// in all three buckets rather than merely "no movies".
    @Test(".empty carries no results in any bucket")
    func emptyIsEmptyEverywhere() {
        #expect(SearchResults.empty.movies.isEmpty)
        #expect(SearchResults.empty.series.isEmpty)
        #expect(SearchResults.empty.episodes.isEmpty)
    }

    /// The three buckets stay separate: search renders them as distinct sections, so a movie
    /// must never leak into the episodes list.
    @Test("the three buckets stay separate")
    func bucketsStaySeparate() {
        let results = SearchResults(
            movies: [LibraryFixtures.movie()],
            series: [LibraryFixtures.series()],
            episodes: [LibraryFixtures.episode(), LibraryFixtures.episode(id: "e2")]
        )
        #expect(results.movies.count == 1)
        #expect(results.series.count == 1)
        #expect(results.episodes.count == 2)
        #expect(results != SearchResults.empty)
    }
}

@Suite("Library scoping")
struct LibraryScopingTests {
    /// Favorites is its own scope rather than a filter, because it queries recursively with no
    /// parent — a collection scope can't express that.
    @Test("favorites is a scope of its own, distinct from any collection")
    func favoritesIsItsOwnScope() {
        #expect(LibraryScope.favorites != .collection(CollectionID(rawValue: "any")))
        #expect(LibraryScope.collection(CollectionID(rawValue: "a"))
                != .collection(CollectionID(rawValue: "b")))
        #expect(LibraryScope.favorites == .favorites)
    }

    /// Watch state and favourites deliberately left this struct — genre is the one filter left.
    @Test("a fresh filter is empty, so a grid starts unfiltered")
    func filterDefaultsToEmpty() {
        #expect(ItemFilter().genres.isEmpty)
        #expect(ItemFilter() == ItemFilter(genres: []))
        #expect(ItemFilter(genres: ["Drama"]) != ItemFilter())
    }

    @Test("every search scope is distinct")
    func searchScopesAreDistinct() {
        #expect(Set(SearchScope.allCases).count == SearchScope.allCases.count)
        #expect(SearchScope.allCases.contains(.all))
    }
}

@Suite("Data.sha256Hex")
struct DataSHA256HexTests
{
    /// A published NIST/FIPS-180 vector, so this pins the digest itself rather than merely
    /// "some stable string" — thumbnail cache filenames are derived from it and must not move.
    @Test("matches the published SHA-256 vector for \"abc\"")
    func knownVector() {
        let digest = Data("abc".utf8).sha256Hex
        #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("the empty input has the published empty digest")
    func emptyVector() {
        #expect(Data().sha256Hex == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    /// Lowercase, fixed width: the value goes into a filename, so casing and length are part of
    /// the contract, not cosmetic.
    @Test("the digest is 64 lowercase hex characters")
    func formatting() {
        let digest = Data("some/smb/path.mkv".utf8).sha256Hex
        #expect(digest.count == 64)
        #expect(digest == digest.lowercased())
        let isAllHex = digest.allSatisfy(\.isHexDigit)
        #expect(isAllHex)
    }

    @Test("different inputs digest differently")
    func distinctInputs() {
        #expect(Data("a".utf8).sha256Hex != Data("b".utf8).sha256Hex)
    }
}
