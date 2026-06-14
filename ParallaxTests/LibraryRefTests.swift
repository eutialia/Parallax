import Testing
import ParallaxCore
import ParallaxJellyfin
@testable import Parallax

@Suite("Library source identity")
struct LibraryRefTests {
    @Test("Same collection id under different sources is not equal")
    func sourceDisambiguates() {
        let a = LibraryRef(source: .jellyfin(ServerID(rawValue: "A")), collection: CollectionID(rawValue: "shared"))
        let b = LibraryRef(source: .jellyfin(ServerID(rawValue: "B")), collection: CollectionID(rawValue: "shared"))
        #expect(a != b)
    }
    @Test("Same source and collection id are equal")
    func sameRefEqual() {
        let a = LibraryRef(source: .jellyfin(ServerID(rawValue: "A")), collection: CollectionID(rawValue: "c1"))
        let b = LibraryRef(source: .jellyfin(ServerID(rawValue: "A")), collection: CollectionID(rawValue: "c1"))
        #expect(a == b)
    }
    @Test("LibraryEntry.id is its LibraryRef")
    func entryIdentity() {
        let entry = LibraryEntry(
            source: .jellyfin(ServerID(rawValue: "A")),
            collection: MediaCollection(id: CollectionID(rawValue: "c1"), name: "Movies", collectionType: .movies, primaryTag: nil)
        )
        #expect(entry.id == LibraryRef(source: .jellyfin(ServerID(rawValue: "A")), collection: CollectionID(rawValue: "c1")))
    }
}
