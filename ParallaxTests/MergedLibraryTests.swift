import Testing
import Foundation
import ParallaxCore
import ParallaxJellyfin
@testable import Parallax

@Suite("Grouped library list")
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

    private func collection(
        _ id: String,
        _ name: String,
        type: CollectionType = .movies
    ) -> MediaCollection {
        MediaCollection(id: CollectionID(rawValue: id), name: name, collectionType: type, primaryTag: nil)
    }

    /// A Jellyfin repo factory keyed by session id, so per-server grouping is observable. Only
    /// Jellyfin collections flow through a repo — SMB libraries are the configured shares themselves
    /// (one `LibraryEntry` per share, network-free), so they're not faked here. A session id absent
    /// from `failing` succeeds with its collections; a present one throws.
    private func jellyfinRepo(
        _ bySession: [ServerID: [MediaCollection]],
        failing: Set<ServerID> = []
    ) -> @Sendable (Session) async -> any MediaRepository {
        { session in
            let repo = FakeMediaRepository()
            if failing.contains(session.id) {
                repo.collectionsResult = .failure(AppError.network(URLError(.notConnectedToInternet)))
            } else {
                repo.collectionsResult = .success(bySession[session.id] ?? [])
            }
            return repo
        }
    }

    // MARK: - Section order

    @Test("Jellyfin sections rank above SMB even when an SMB server was added FIRST")
    func jellyfinOutranksSMBRegardlessOfAddOrder() async {
        // The real config that exposed this: the NAS was added before the Jellyfin server, so pure
        // add order put a metadata-less file wall above the app's primary source.
        let jSession = session("jelly")
        let nas1 = smbServer("nas-1", host: "nas1.local", shares: ["Films"])
        let nas2 = smbServer("nas-2", host: "nas2.local", shares: ["Archive"])
        let repo = jellyfinRepo([jSession.id: [collection("c1", "Movies")]])

        let outcome = await MergedLibrary.resolve(
            sessions: [jSession],
            servers: [nas1, jSession.persisted, nas2],
            jellyfinRepo: repo
        )

        #expect(outcome.groups.map(\.id) == [
            .jellyfin(jSession.id), .smb(nas1.id), .smb(nas2.id),
        ])
        #expect(outcome.groups.map(\.title) == ["Server jelly", "nas1.local", "nas2.local"])
        // The flattened view (stale-tab snapping reads it) follows the same order.
        #expect(outcome.entries.map(\.collection.name) == ["Movies", "Films", "Archive"])
        #expect(outcome.hasFailures == false)
    }

    @Test("Within a kind, sections keep the order the user added them")
    func addOrderIsTheTieBreakWithinAKind() async {
        // Two Jellyfin servers and two NAS boxes, added interleaved. Ranking by kind must not
        // scramble each kind's internal add order — nor let the concurrent fan-out decide it.
        let first = session("first")
        let second = session("second")
        let nasA = smbServer("nas-a", host: "a.local", shares: ["A"])
        let nasB = smbServer("nas-b", host: "b.local", shares: ["B"])
        let repo = jellyfinRepo([
            first.id: [collection("c1", "Movies")],
            second.id: [collection("c2", "Shows")],
        ])

        let outcome = await MergedLibrary.resolve(
            sessions: [first, second],
            servers: [nasA, second.persisted, nasB, first.persisted],
            jellyfinRepo: repo
        )

        // Jellyfin band in add order (second was added before first), then the SMB band likewise.
        #expect(outcome.groups.map(\.id) == [
            .jellyfin(second.id), .jellyfin(first.id), .smb(nasA.id), .smb(nasB.id),
        ])
    }

    // MARK: - No cross-server merging

    @Test("Two servers with identically named libraries stay SEPARATE groups with distinct refs")
    func sameNamedLibrariesAreNeverMerged() async {
        let a = session("a")
        let b = session("b")
        let repo = jellyfinRepo([
            a.id: [collection("c1", "Movies"), collection("c2", "Shows")],
            b.id: [collection("c1", "Movies")],
        ])

        let outcome = await MergedLibrary.resolve(
            sessions: [a, b],
            servers: [a.persisted, b.persisted],
            jellyfinRepo: repo
        )

        #expect(outcome.groups.count == 2)
        // "Movies" appears twice — once per server — rather than being unioned into one library.
        #expect(outcome.entries.filter { $0.collection.name == "Movies" }.count == 2)
        // Even sharing a raw CollectionID, the source tag keeps their tab identities distinct.
        #expect(Set(outcome.entries.map(\.id)).count == outcome.entries.count)
    }

    @Test("A Jellyfin collection and an SMB share sharing a raw id still get distinct ids")
    func sourceDisambiguatesSharedID() async {
        let jSession = session("jelly")
        // The SMB share name "shared" round-trips to a CollectionID that collides with the Jellyfin
        // collection's raw id — the source tag must still split them apart.
        let smb = smbServer("nas-1", host: "nas.local", shares: ["shared"])
        let repo = jellyfinRepo([jSession.id: [collection("shared", "J Movies")]])

        let entries = await MergedLibrary.resolve(
            sessions: [jSession],
            servers: [jSession.persisted, smb],
            jellyfinRepo: repo
        ).entries

        #expect(entries.count == 2)
        #expect(Set(entries.map(\.id)).count == 2)
    }

    // MARK: - Filtering

    @Test("Hidden collections are filtered PER SERVER — hiding on one server spares the other's namesake")
    func hiddenIsPerServer() async {
        let a = session("a")
        let b = session("b")
        let repo = jellyfinRepo([
            a.id: [collection("shared-id", "Movies"), collection("a2", "Shows")],
            b.id: [collection("shared-id", "Movies")],
        ])

        let outcome = await MergedLibrary.resolve(
            sessions: [a, b],
            servers: [a.persisted, b.persisted],
            // Same raw collection id on both servers; only server A's is hidden.
            hiddenCollectionIDs: [a.id: ["shared-id"]],
            jellyfinRepo: repo
        )

        #expect(outcome.groups.count == 2)
        #expect(outcome.groups[0].entries.map(\.collection.name) == ["Shows"])
        #expect(outcome.groups[1].entries.map(\.collection.name) == ["Movies"])
    }

    @Test("Collections this app can't browse (music/photos) are dropped for every root")
    func unbrowsableCollectionsDropped() async {
        let jSession = session("jelly")
        let repo = jellyfinRepo([jSession.id: [
            collection("c1", "Movies"),
            collection("c2", "Music", type: .other("music")),
            collection("c3", "Shows", type: .tvShows),
        ]])

        let outcome = await MergedLibrary.resolve(
            sessions: [jSession],
            servers: [jSession.persisted],
            jellyfinRepo: repo
        )

        #expect(outcome.entries.map(\.collection.name) == ["Movies", "Shows"])
    }

    @Test("A server whose every library is hidden contributes NO group — not an empty titled section")
    func fullyHiddenServerContributesNoGroup() async {
        let a = session("a")
        let b = session("b")
        let repo = jellyfinRepo([
            a.id: [collection("a1", "Movies")],
            b.id: [collection("b1", "Shows")],
        ])

        let outcome = await MergedLibrary.resolve(
            sessions: [a, b],
            servers: [a.persisted, b.persisted],
            hiddenCollectionIDs: [b.id: ["b1"]],
            jellyfinRepo: repo
        )

        #expect(outcome.groups.map(\.id) == [.jellyfin(a.id)])
        // Hiding everything is a deliberate user choice, never a stall.
        #expect(outcome.hasFailures == false)
    }

    @Test("An SMB server with no selected shares contributes no group")
    func smbWithNoSharesContributesNoGroup() async {
        let smb = smbServer("nas-1", host: "nas.local", shares: [])

        let outcome = await MergedLibrary.resolve(
            sessions: [],
            servers: [smb],
            jellyfinRepo: jellyfinRepo([:])
        )

        #expect(outcome.groups.isEmpty)
        #expect(outcome.hasFailures == false)
    }

    // MARK: - Partial failure

    @Test("One server down: its group drops out and only ITS id is flagged — the rest survive")
    func perServerFailureIsIsolated() async {
        let up = session("up")
        let down = session("down")
        let smb = smbServer("nas-1", host: "nas.local", shares: ["Films"])
        let repo = jellyfinRepo(
            [up.id: [collection("c1", "Movies")], down.id: [collection("c2", "Shows")]],
            failing: [down.id]
        )

        let outcome = await MergedLibrary.resolve(
            sessions: [up, down],
            servers: [up.persisted, down.persisted, smb],
            jellyfinRepo: repo
        )

        // The healthy Jellyfin server and the local shares are untouched by the dead one.
        #expect(outcome.groups.map(\.id) == [.jellyfin(up.id), .smb(smb.id)])
        // Only the failed source is flagged, so recovery re-pulls just that one.
        #expect(outcome.failedSourceIDs == [.jellyfin(down.id)])
        #expect(outcome.hasFailures)
    }

    @Test("SMB-only: no Jellyfin fetch, so never a stall")
    func smbOnlyIsNeverStalled() async {
        let smb = smbServer("nas-1", host: "nas.local", shares: ["Films"])

        let outcome = await MergedLibrary.resolve(
            sessions: [],
            servers: [smb],
            jellyfinRepo: jellyfinRepo([:])
        )

        #expect(outcome.entries.map(\.collection.name) == ["Films"])
        #expect(outcome.entries[0].source.sourceID == .smb(smb.id))
        // An SMB-only config must not trigger offline recovery on a network it doesn't need.
        #expect(outcome.hasFailures == false)
    }

    @Test("A persisted Jellyfin row with no live session is skipped silently, NOT flagged as failed")
    func signedOutJellyfinRowIsSkippedNotFailed() async {
        // Its Keychain token was lost, so `ServerStore` rebuilt no session for it. Settings surfaces
        // that state; the library list must not report it as an offline failure and spin recovery.
        let live = session("live")
        let signedOut = session("signed-out")
        let repo = jellyfinRepo([live.id: [collection("c1", "Movies")]])

        let outcome = await MergedLibrary.resolve(
            sessions: [live],
            servers: [live.persisted, signedOut.persisted],
            jellyfinRepo: repo
        )

        #expect(outcome.groups.map(\.id) == [.jellyfin(live.id)])
        #expect(outcome.hasFailures == false)
    }

    // MARK: - Section titles

    @Test("A single source keeps the plain \"Libraries\" title; two or more title each by server")
    func sectionTitlesDependOnSourceCount() async {
        let a = session("a")
        let b = session("b")
        let repo = jellyfinRepo([
            a.id: [collection("a1", "Movies")],
            b.id: [collection("b1", "Shows")],
        ])

        let single = await MergedLibrary.resolve(
            sessions: [a], servers: [a.persisted], jellyfinRepo: repo
        ).groups
        #expect(single.needsPerSourceTitles == false)
        #expect(single.sectionTitle(for: single[0]) == "Libraries")

        let both = await MergedLibrary.resolve(
            sessions: [a, b], servers: [a.persisted, b.persisted], jellyfinRepo: repo
        ).groups
        #expect(both.needsPerSourceTitles)
        #expect(both.map { both.sectionTitle(for: $0) } == ["Server a", "Server b"])
    }
}
