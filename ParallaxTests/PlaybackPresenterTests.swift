import Testing
import Foundation
import ParallaxCore
import ParallaxJellyfin
@testable import Parallax

/// Which `PlaybackPresenter.play` entry point a case exercises.
private enum PlayTargetKind: String, Sendable, CustomTestStringConvertible {
    case itemID, detail
    var testDescription: String { rawValue }
}

@MainActor
struct PlaybackPresenterTests {
    /// The one server every test in this suite plays from.
    private func session() -> Session { makeSession("s1", name: "S1") }

    /// Both `play` entry points × both restart intents. The Jellyfin session rides
    /// INSIDE the target after the relocation, so every cell re-checks that it's
    /// carried — plus that `fromBeginning` threads through unchanged.
    @Test("play sets a request whose target carries the item, the session, and the restart intent",
          arguments: [PlayTargetKind.itemID, .detail], [false, true])
    fileprivate func playSetsRequest(kind: PlayTargetKind, fromBeginning: Bool) throws {
        let presenter = PlaybackPresenter()
        #expect(presenter.request == nil)
        let s = session()
        let itemID = ItemID(rawValue: "ep-1")

        switch kind {
        case .itemID: presenter.play(itemID, in: s, fromBeginning: fromBeginning)
        case .detail: presenter.play(PlayerFixtures.movieDetail(), in: s, fromBeginning: fromBeginning)
        }

        let target = try #require(presenter.request?.target)
        switch (kind, target) {
        case (.itemID, .itemID(let id, let carried, let restart)):
            #expect(id == itemID)
            #expect(carried.id == s.id)
            #expect(restart == fromBeginning)
        case (.detail, .detail(_, let carried, let restart)):
            #expect(carried.id == s.id)
            #expect(restart == fromBeginning)
        default:
            Issue.record("expected a \(kind) target, got \(target)")
        }
    }

    @Test("playSMB sets a .smb target carrying the item + ref (no Jellyfin session)")
    func playSMBSetsSMBTarget() {
        let presenter = PlaybackPresenter()
        #expect(presenter.request == nil)
        let item = makeMovieItem("Media:Movies/Example.mkv", title: "Example")
        let ref = makeSMBRef()
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
        guard case .itemID(let id, _, _) = presenter.request?.target else {
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
        guard case .itemID(let id, _, _) = presenter.request?.target else {
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
        guard case .itemID(let id, _, _) = presenter.request?.target else {
            Issue.record("expected the held pick to present after the grace")
            return
        }
        #expect(id == ItemID(rawValue: "ep-3"))
    }
}
