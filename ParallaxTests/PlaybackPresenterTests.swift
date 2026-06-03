import Testing
import Foundation
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
        #expect(presenter.request?.itemID == ItemID(rawValue: "ep-1"))
        #expect(presenter.request?.session.id == s.id)
    }
}
