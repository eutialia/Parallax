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
}
