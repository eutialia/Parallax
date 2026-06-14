import Testing
import Foundation
import ParallaxCore
import ParallaxJellyfin
@testable import Parallax

@MainActor
struct PlaybackPresenterTests {
    private func session() -> Session {
        Session(
            persisted: PersistedSession(
                id: ServerID(rawValue: "s1"),
                serverURL: URL(string: "https://s1.example.test")!,
                serverName: "S1",
                user: UserSnapshot(id: "u1", name: "U", serverLastUpdatedAt: nil)
            ),
            accessToken: "t1"
        )
    }

    @Test("play sets a request carrying the item id and session")
    func playSetsRequest() {
        let presenter = PlaybackPresenter()
        #expect(presenter.request == nil)
        let s = session()
        presenter.play(ItemID(rawValue: "ep-1"), in: s)
        guard case .itemID(let id) = presenter.request?.target else {
            Issue.record("expected an itemID target")
            return
        }
        #expect(id == ItemID(rawValue: "ep-1"))
        #expect(presenter.request?.session.id == s.id)
    }

    @Test("a second play while presented is dropped (no flicker re-present)")
    func secondPlayDropped() {
        let presenter = PlaybackPresenter()
        let s = session()
        presenter.play(ItemID(rawValue: "ep-1"), in: s)
        let first = presenter.request?.id
        presenter.play(ItemID(rawValue: "ep-2"), in: s)
        #expect(presenter.request?.id == first)
        guard case .itemID(let id) = presenter.request?.target else {
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
        guard case .itemID(let id) = presenter.request?.target else {
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
        guard case .itemID(let id) = presenter.request?.target else {
            Issue.record("expected the held pick to present after the grace")
            return
        }
        #expect(id == ItemID(rawValue: "ep-3"))
    }
}
