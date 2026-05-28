import Foundation

public struct UserItemData: Sendable, Hashable, Codable {
    public let played: Bool
    public let playbackPositionTicks: Int64
    public let playCount: Int
    public let isFavorite: Bool

    public init(played: Bool, playbackPositionTicks: Int64, playCount: Int, isFavorite: Bool) {
        self.played = played
        self.playbackPositionTicks = playbackPositionTicks
        self.playCount = playCount
        self.isFavorite = isFavorite
    }

    // Derived at the call site: runtime ticks live on the parent item
    // (Movie/Episode), not on UserItemData. Returns nil when there's
    // no runtime to divide by or the runtime is zero.
    public func playedFraction(runtimeTicks: Int64?) -> Double? {
        guard let runtimeTicks, runtimeTicks > 0 else { return nil }
        return Double(playbackPositionTicks) / Double(runtimeTicks)
    }
}
