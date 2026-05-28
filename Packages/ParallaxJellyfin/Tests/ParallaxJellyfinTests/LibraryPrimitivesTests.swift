import Foundation
import Testing
@testable import ParallaxJellyfin

@Suite("Library primitives")
struct LibraryPrimitivesTests {
    @Test("Typed ID wrappers are distinct value types")
    func typedIDs() {
        let item = ItemID(rawValue: "abc")
        let coll = CollectionID(rawValue: "abc")
        let tag = ImageTag(rawValue: "abc")
        #expect(item.rawValue == coll.rawValue)
        #expect(item.rawValue == tag.rawValue)
        // The point of the wrappers is that the type system rejects
        // cross-assignment. That's a compile-time guarantee — these
        // runtime checks only prove the value-equality semantics on
        // `rawValue`, not the type-system distinctness.
        #expect(ItemID(rawValue: "abc") == ItemID(rawValue: "abc"))
        #expect(ItemID(rawValue: "abc") != ItemID(rawValue: "xyz"))
    }

    @Test("Page exposes items, total, and nextCursor")
    func pageShape() {
        let cursor = PageCursor.startIndex(50)
        let page = Page(items: [1, 2, 3], total: 120, nextCursor: cursor)
        #expect(page.items == [1, 2, 3])
        #expect(page.total == 120)
        #expect(page.nextCursor == cursor)
    }

    @Test("ItemSort default for library is title ascending")
    func itemSortDefault() {
        let s = ItemSort.defaultForLibrary
        #expect(s.field == .title)
        #expect(s.direction == .ascending)
    }

    @Test("ItemFilter default is no constraints")
    func itemFilterDefault() {
        let f = ItemFilter()
        #expect(f.watchState == .all)
        #expect(f.favoritesOnly == false)
    }

    // searchResultsEmpty is exercised in Task 4 once Movie/Series/Episode exist.
    // @Test("SearchResults default is empty")
    // func searchResultsEmpty() {
    //     let r = SearchResults(movies: [], series: [], episodes: [])
    //     #expect(r.movies.isEmpty)
    //     #expect(r.series.isEmpty)
    //     #expect(r.episodes.isEmpty)
    // }
}
