import Testing
import Foundation
import ParallaxCore
import ParallaxJellyfin
@testable import Parallax

@Suite("Library source identity")
struct LibraryRefTests {
    /// A Jellyfin session whose server id is `id`, so `.jellyfin(session).sourceID`
    /// is `.jellyfin(ServerID(id))` — what `LibraryEntry.id` derives its ref from.
    private func session(id: String) -> Session {
        Session(
            id: ServerID(rawValue: id),
            data: JellyfinServerData(
                serverURL: URL(string: "https://\(id).example.test")!,
                serverName: id,
                user: UserSnapshot(id: "u1", name: "U", serverLastUpdatedAt: nil)
            ),
            accessToken: "t"
        )
    }

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
        let entry = LibraryEntry(
            source: .jellyfin(session(id: "A")),
            collection: MediaCollection(id: CollectionID(rawValue: "c1"), name: "Movies", collectionType: .movies, primaryTag: nil)
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
