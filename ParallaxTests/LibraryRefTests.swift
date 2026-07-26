import Testing
import Foundation
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
    @Test("LibraryEntry.id is its LibraryRef, derived via source.sourceID")
    func entryIdentity() {
        // A Jellyfin session whose server id is "A", so `.jellyfin(session).sourceID`
        // is `.jellyfin(ServerID("A"))` — what `LibraryEntry.id` derives its ref from.
        let entry = LibraryEntry(
            source: makeJellyfinSource("A"),
            collection: makeCollection("c1", "Movies")
        )
        #expect(entry.id == LibraryRef(source: .jellyfin(ServerID(rawValue: "A")), collection: CollectionID(rawValue: "c1")))
    }
    @Test("SMB and Jellyfin source ids with the same raw string do not collide")
    func smbJellyfinNoCollision() {
        let id = ServerID(rawValue: "nas-1")
        let j = MediaSourceID.jellyfin(id)
        let s = MediaSourceID.smb(id)
        #expect(j != s)
        let c = CollectionID(rawValue: "c")
        #expect(LibraryRef(source: j, collection: c) != LibraryRef(source: s, collection: c))
    }
}
