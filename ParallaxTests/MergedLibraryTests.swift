import Testing
import Foundation
import ParallaxCore
import ParallaxJellyfin
@testable import Parallax

@Suite("Merged library list")
@MainActor
struct MergedLibraryTests {
    // MARK: - Fixtures

    private func session(_ rawID: String) -> Session {
        Session(
            id: ServerID(rawValue: rawID),
            data: JellyfinServerData(
                serverURL: URL(string: "https://\(rawID).example.test")!,
                serverName: "Server \(rawID)",
                user: UserSnapshot(id: "user-\(rawID)", name: "User", serverLastUpdatedAt: nil)
            ),
            accessToken: "token-\(rawID)"
        )
    }

    private func smbServer(_ rawID: String, host: String) -> PersistedServer {
        PersistedServer(
            id: ServerID(rawValue: rawID),
            kind: .smb(SMBServerData(host: host, share: "media", root: "", username: "guest", domain: ""))
        )
    }

    private func collection(_ id: String, _ name: String) -> MediaCollection {
        MediaCollection(id: CollectionID(rawValue: id), name: name, collectionType: .movies, primaryTag: nil)
    }

    /// A repo factory that hands each source its own canned `collections()` keyed by
    /// `MediaSourceID`, so the merge order and per-source tagging are observable.
    private func factory(
        _ bySource: [MediaSourceID: [MediaCollection]]
    ) -> @Sendable (LibrarySource) async -> any MediaRepository {
        { source in
            let repo = FakeMediaRepository()
            repo.collectionsResult = .success(bySource[source.sourceID] ?? [])
            return repo
        }
    }

    // MARK: - Tests

    @Test("Jellyfin + one SMB server: both sources, Jellyfin first, each tagged by source")
    func mergesBothSources() async {
        let jSession = session("jelly")
        let smb = smbServer("nas-1", host: "nas.local")
        let repoFactory = factory([
            .jellyfin(jSession.id): [collection("c1", "Movies"), collection("c2", "Shows")],
            .smb(smb.id): [collection("s1", "Films"), collection("s2", "Series")],
        ])

        let entries = await MergedLibrary.entries(
            jellyfinSession: jSession,
            smbServers: [smb],
            repoFactory: repoFactory
        )

        #expect(entries.count == 4)
        // Order: Jellyfin collections first, then SMB.
        #expect(entries.map(\.collection.name) == ["Movies", "Shows", "Films", "Series"])

        // First two are Jellyfin-sourced, last two SMB-sourced.
        let sources = entries.map(\.source.sourceID)
        #expect(sources == [
            .jellyfin(jSession.id), .jellyfin(jSession.id),
            .smb(smb.id), .smb(smb.id),
        ])

        // No two entries collide on a LibraryRef (the source disambiguates).
        #expect(Set(entries.map(\.id)).count == entries.count)
    }

    @Test("A Jellyfin and SMB collection sharing a raw CollectionID still get distinct ids")
    func sourceDisambiguatesSharedCollectionID() async {
        let jSession = session("jelly")
        let smb = smbServer("nas-1", host: "nas.local")
        // Both sources expose a collection with the SAME raw CollectionID "shared".
        let repoFactory = factory([
            .jellyfin(jSession.id): [collection("shared", "J Movies")],
            .smb(smb.id): [collection("shared", "S Movies")],
        ])

        let entries = await MergedLibrary.entries(
            jellyfinSession: jSession,
            smbServers: [smb],
            repoFactory: repoFactory
        )

        #expect(entries.count == 2)
        #expect(entries[0].id != entries[1].id)
        #expect(Set(entries.map(\.id)).count == 2)
    }

    @Test("Jellyfin-only (no SMB servers): only Jellyfin entries — today's behavior")
    func jellyfinOnly() async {
        let jSession = session("jelly")
        let repoFactory = factory([
            .jellyfin(jSession.id): [collection("c1", "Movies"), collection("c2", "Shows")],
        ])

        let entries = await MergedLibrary.entries(
            jellyfinSession: jSession,
            smbServers: [],
            repoFactory: repoFactory
        )

        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.source.sourceID == .jellyfin(jSession.id) })
    }

    @Test("nil session + one SMB server: only SMB entries — the helper is source-symmetric")
    func smbOnly() async {
        let smb = smbServer("nas-1", host: "nas.local")
        let repoFactory = factory([
            .smb(smb.id): [collection("s1", "Films")],
        ])

        let entries = await MergedLibrary.entries(
            jellyfinSession: nil,
            smbServers: [smb],
            repoFactory: repoFactory
        )

        #expect(entries.count == 1)
        #expect(entries[0].source.sourceID == .smb(smb.id))
        #expect(entries[0].collection.name == "Films")
    }
}
