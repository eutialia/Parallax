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

    private func smbServer(_ rawID: String, host: String, shares: [String]) -> PersistedServer {
        PersistedServer(
            id: ServerID(rawValue: rawID),
            kind: .smb(SMBServerData(host: host, username: "guest", domain: "", shares: shares))
        )
    }

    private func collection(_ id: String, _ name: String) -> MediaCollection {
        MediaCollection(id: CollectionID(rawValue: id), name: name, collectionType: .movies, primaryTag: nil)
    }

    /// A Jellyfin repo factory keyed by session id, so the merge order + Jellyfin tagging are
    /// observable. Only Jellyfin collections flow through a repo — SMB libraries are the configured
    /// shares themselves (one `LibraryEntry` per share, network-free), so they're not faked here.
    private func jellyfinRepo(
        _ bySession: [ServerID: [MediaCollection]]
    ) -> @Sendable (Session) async -> any MediaRepository {
        { session in
            let repo = FakeMediaRepository()
            repo.collectionsResult = .success(bySession[session.id] ?? [])
            return repo
        }
    }

    /// A Jellyfin repo factory whose `collections()` always throws — the offline / server-down case
    /// that drives `jellyfinCollectionsFailed`.
    private func failingJellyfinRepo() -> @Sendable (Session) async -> any MediaRepository {
        { _ in
            let repo = FakeMediaRepository()
            repo.collectionsResult = .failure(AppError.network(URLError(.notConnectedToInternet)))
            return repo
        }
    }

    // MARK: - Tests

    @Test("Jellyfin + one SMB server: Jellyfin collections first, then one entry per SMB share")
    func mergesBothSources() async {
        let jSession = session("jelly")
        let smb = smbServer("nas-1", host: "nas.local", shares: ["Films", "Series"])
        let repo = jellyfinRepo([jSession.id: [collection("c1", "Movies"), collection("c2", "Shows")]])

        let outcome = await MergedLibrary.resolve(
            jellyfinSession: jSession,
            smbServers: [smb],
            jellyfinRepo: repo
        )
        let entries = outcome.entries

        #expect(entries.count == 4)
        // Order: Jellyfin collections first, then the SMB shares in configured order.
        #expect(entries.map(\.collection.name) == ["Movies", "Shows", "Films", "Series"])

        // First two are Jellyfin-sourced, last two SMB-sourced.
        let sources = entries.map(\.source.sourceID)
        #expect(sources == [
            .jellyfin(jSession.id), .jellyfin(jSession.id),
            .smb(smb.id), .smb(smb.id),
        ])

        // No two entries collide on a LibraryRef (the source disambiguates).
        #expect(Set(entries.map(\.id)).count == entries.count)
        // A successful fetch is never a stall.
        #expect(outcome.jellyfinCollectionsFailed == false)
    }

    @Test("A Jellyfin collection and an SMB share sharing a raw id still get distinct ids")
    func sourceDisambiguatesSharedID() async {
        let jSession = session("jelly")
        // The SMB share name "shared" round-trips to a CollectionID that collides with the Jellyfin
        // collection's raw id — the source tag must still split them apart.
        let smb = smbServer("nas-1", host: "nas.local", shares: ["shared"])
        let repo = jellyfinRepo([jSession.id: [collection("shared", "J Movies")]])

        let entries = await MergedLibrary.resolve(
            jellyfinSession: jSession,
            smbServers: [smb],
            jellyfinRepo: repo
        ).entries

        #expect(entries.count == 2)
        #expect(entries[0].id != entries[1].id)
        #expect(Set(entries.map(\.id)).count == 2)
    }

    @Test("Jellyfin-only (no SMB servers): only Jellyfin entries")
    func jellyfinOnly() async {
        let jSession = session("jelly")
        let repo = jellyfinRepo([jSession.id: [collection("c1", "Movies"), collection("c2", "Shows")]])

        let entries = await MergedLibrary.resolve(
            jellyfinSession: jSession,
            smbServers: [],
            jellyfinRepo: repo
        ).entries

        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.source.sourceID == .jellyfin(jSession.id) })
    }

    @Test("nil session + one SMB server: only the SMB share entries — the helper is source-symmetric")
    func smbOnly() async {
        let smb = smbServer("nas-1", host: "nas.local", shares: ["Films"])

        let outcome = await MergedLibrary.resolve(
            jellyfinSession: nil,
            smbServers: [smb],
            jellyfinRepo: jellyfinRepo([:])
        )

        #expect(outcome.entries.count == 1)
        #expect(outcome.entries[0].source.sourceID == .smb(smb.id))
        #expect(outcome.entries[0].collection.name == "Films")
        // No Jellyfin session means no Jellyfin fetch — never a stall (an SMB-only config must not
        // trigger offline recovery on a network it doesn't need).
        #expect(outcome.jellyfinCollectionsFailed == false)
    }

    @Test("Jellyfin collections() throws: flags the failure but keeps the SMB shares")
    func jellyfinFetchFailureFlaggedSMBPreserved() async {
        let jSession = session("jelly")
        let smb = smbServer("nas-1", host: "nas.local", shares: ["Films", "Series"])

        let outcome = await MergedLibrary.resolve(
            jellyfinSession: jSession,
            smbServers: [smb],
            jellyfinRepo: failingJellyfinRepo()
        )

        // The Jellyfin half drops out, but the local SMB shares survive — a down server can't blank
        // the configured shares.
        #expect(outcome.entries.map(\.collection.name) == ["Films", "Series"])
        #expect(outcome.entries.allSatisfy { $0.source.sourceID == .smb(smb.id) })
        // ...and the failure is reported so the nav roots auto-recover on reconnect.
        #expect(outcome.jellyfinCollectionsFailed)
    }

    @Test("Jellyfin-only fetch failure: empty entries AND flagged stalled")
    func jellyfinOnlyFetchFailureStalled() async {
        let jSession = session("jelly")

        let outcome = await MergedLibrary.resolve(
            jellyfinSession: jSession,
            smbServers: [],
            jellyfinRepo: failingJellyfinRepo()
        )

        #expect(outcome.entries.isEmpty)
        #expect(outcome.jellyfinCollectionsFailed)
    }
}
