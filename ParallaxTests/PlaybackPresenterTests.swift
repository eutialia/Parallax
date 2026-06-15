import Testing
import Foundation
import ParallaxCore
import ParallaxJellyfin
@testable import Parallax

@MainActor
struct PlaybackPresenterTests {
    private func session() -> Session {
        Session(
            id: ServerID(rawValue: "s1"),
            data: JellyfinServerData(
                serverURL: URL(string: "https://s1.example.test")!,
                serverName: "S1",
                user: UserSnapshot(id: "u1", name: "U", serverLastUpdatedAt: nil)
            ),
            accessToken: "t1"
        )
    }

    private func smbRef(id: String = "smb-nas|Media|Movies") -> SMBServerRef {
        SMBServerRef(
            id: ServerID(rawValue: id),
            data: SMBServerData(host: "nas.local", share: "Media", root: "Movies", username: "alice", domain: "WORKGROUP")
        )
    }

    private func movieItem(id: String = "Media:Movies/Example.mkv", title: String = "Example") -> Item {
        .movie(Movie(
            id: ItemID(rawValue: id), title: title, overview: nil, year: nil, runtime: nil,
            communityRating: nil, officialRating: nil, genres: [],
            primaryTag: nil, backdropTags: [], logoTag: nil, thumbTag: nil, dateAdded: nil,
            userData: UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: false)
        ))
    }

    @Test("play sets a request carrying the item id and session")
    func playSetsRequest() {
        let presenter = PlaybackPresenter()
        #expect(presenter.request == nil)
        let s = session()
        presenter.play(ItemID(rawValue: "ep-1"), in: s)
        // The Jellyfin session now rides INSIDE the target after the relocation —
        // a regression check that `play(_:in:)` still carries it.
        guard case .itemID(let id, let carried) = presenter.request?.target else {
            Issue.record("expected an itemID target")
            return
        }
        #expect(id == ItemID(rawValue: "ep-1"))
        #expect(carried.id == s.id)
    }

    @Test("play(_ detail:in:) sets a .detail target carrying the session (relocation regression)")
    func playDetailCarriesSession() {
        let presenter = PlaybackPresenter()
        let s = session()
        presenter.play(PlayerFixtures.movieDetail(), in: s)
        guard case .detail(_, let carried) = presenter.request?.target else {
            Issue.record("expected a detail target")
            return
        }
        #expect(carried.id == s.id)
    }

    @Test("playSMB sets a .smb target carrying the item + ref (no Jellyfin session)")
    func playSMBSetsSMBTarget() {
        let presenter = PlaybackPresenter()
        #expect(presenter.request == nil)
        let item = movieItem()
        let ref = smbRef()
        presenter.playSMB(item, ref: ref)
        guard case .smb(let carriedItem, let carriedRef) = presenter.request?.target else {
            Issue.record("expected an smb target")
            return
        }
        #expect(carriedItem.id == item.id)
        #expect(carriedRef == ref)
    }

    @Test("a second play while presented is dropped (no flicker re-present)")
    func secondPlayDropped() {
        let presenter = PlaybackPresenter()
        let s = session()
        presenter.play(ItemID(rawValue: "ep-1"), in: s)
        let first = presenter.request?.id
        presenter.play(ItemID(rawValue: "ep-2"), in: s)
        #expect(presenter.request?.id == first)
        guard case .itemID(let id, _) = presenter.request?.target else {
            Issue.record("expected an itemID target")
            return
        }
        #expect(id == ItemID(rawValue: "ep-1"))
    }

    @Test("dismiss clears the request and a new play presents again")
    func dismissClearsRequest() {
        // .zero grace: skip the teardown latch — this test is about the clear,
        // not the transition window.
        let presenter = PlaybackPresenter(teardownGrace: .zero)
        let s = session()
        presenter.play(ItemID(rawValue: "ep-1"), in: s)
        presenter.dismiss()
        #expect(presenter.request == nil)
        presenter.play(ItemID(rawValue: "ep-2"), in: s)
        guard case .itemID(let id, _) = presenter.request?.target else {
            Issue.record("expected an itemID target")
            return
        }
        #expect(id == ItemID(rawValue: "ep-2"))
    }

    @Test("a play during the dismissal's teardown grace is held — no second player over a stopping engine — then presented once the grace expires (latest pick wins)")
    func playDuringTeardownHeldThenPresented() async throws {
        let presenter = PlaybackPresenter(teardownGrace: .milliseconds(20))
        let s = session()
        presenter.play(ItemID(rawValue: "ep-1"), in: s)
        presenter.dismiss()
        presenter.play(ItemID(rawValue: "ep-2"), in: s)
        presenter.play(ItemID(rawValue: "ep-3"), in: s)
        // Held, not mounted, while the outgoing player is still tearing down.
        #expect(presenter.request == nil)
        // Poll, don't fixed-sleep: under parallel test load the presenter's
        // grace task can wake well after its nominal deadline.
        for _ in 0..<200 where presenter.request == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .itemID(let id, _) = presenter.request?.target else {
            Issue.record("expected the held pick to present after the grace")
            return
        }
        #expect(id == ItemID(rawValue: "ep-3"))
    }
}
