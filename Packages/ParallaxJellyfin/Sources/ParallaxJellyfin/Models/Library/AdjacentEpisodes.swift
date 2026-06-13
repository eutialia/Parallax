import Foundation

/// The previous/next episode around a given episode in airing order, composed
/// client-side from the server's `adjacentTo` window (`GET /Shows/{id}/Episodes`,
/// which returns up to three items — previous, the item itself, next). Jellyfin
/// has no first-class "previous episode" endpoint, and `/Shows/NextUp` is
/// watch-history driven (wrong for literal succession), so this adjacency window
/// is the canonical neighbor source for the in-player next/previous buttons and
/// end-of-episode autoplay.
public struct AdjacentEpisodes: Sendable, Hashable {
    public let previous: Episode?
    public let next: Episode?

    public init(previous: Episode?, next: Episode?) {
        self.previous = previous
        self.next = next
    }

    public static let none = AdjacentEpisodes(previous: nil, next: nil)

    /// Resolves neighbors from the `adjacentTo` window. The server returns the
    /// window in `AiredEpisodeOrder` with the queried episode in the middle (or at
    /// one end, when it is the series' first/last), so the neighbors are simply the
    /// elements on either side of it — no `IndexNumber` arithmetic, which would
    /// mishandle interleaved specials and season boundaries.
    public init(around currentID: ItemID, in window: [Episode]) {
        guard let index = window.firstIndex(where: { $0.id == currentID }) else {
            self = .none
            return
        }
        previous = index > 0 ? window[index - 1] : nil
        next = index + 1 < window.count ? window[index + 1] : nil
    }
}
