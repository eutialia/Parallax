import Foundation
import Observation
import ParallaxJellyfin

/// App-level "play this item now" coordinator. Episode taps anywhere (Home,
/// Search, a library grid, a season's episode list) call `play(_:in:)`; a single
/// root-level `fullScreenCover` observes `request` and hosts the player, so
/// playback isn't tied to any one tab's navigation stack.
@Observable
@MainActor
final class PlaybackPresenter {
    struct Request: Identifiable, Hashable {
        let id = UUID()
        let itemID: ItemID
        let session: Session
    }

    var request: Request?

    func play(_ itemID: ItemID, in session: Session) {
        request = Request(itemID: itemID, session: session)
    }
}
