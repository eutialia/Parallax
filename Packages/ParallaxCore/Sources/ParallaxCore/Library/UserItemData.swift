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

    /// Same fraction from the model types' `Duration` runtime; nil when playback
    /// hasn't started or there's no runtime to divide by.
    public func playedFraction(runtime: Duration?) -> Double? {
        guard playbackPositionTicks > 0 else { return nil }
        return playedFraction(runtimeTicks: runtime.map { Int64($0.components.seconds) * 10_000_000 })
    }

    /// Whole minutes left in the item; nil when runtime is unknown or fully watched.
    public func remainingMinutes(runtime: Duration?) -> Int? {
        guard let runtime else { return nil }
        let totalSeconds = runtime.components.seconds
        guard totalSeconds > 0 else { return nil }
        let positionSeconds = playbackPositionTicks / 10_000_000
        let remaining = max(0, totalSeconds - positionSeconds)
        guard remaining > 0 else { return nil }
        return Int((remaining + 59) / 60)
    }

    public func withFavorite(_ isFavorite: Bool) -> UserItemData {
        UserItemData(
            played: played,
            playbackPositionTicks: playbackPositionTicks,
            playCount: playCount,
            isFavorite: isFavorite
        )
    }
}
