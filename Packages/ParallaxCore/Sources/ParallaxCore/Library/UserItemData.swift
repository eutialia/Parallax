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

    /// Partially watched, not yet finished — the one canonical test for "show a Resume-style
    /// affordance / a Play-from-Beginning menu entry" everywhere it's needed (hero, play
    /// buttons, context menus, hero-feed episode selection). `playbackProgress`/duration alone
    /// can't express it (nil for series, and it doesn't encode `!played`), so state it directly
    /// here rather than re-deriving it at each call site.
    public var isInProgress: Bool {
        !played && playbackPositionTicks > 0
    }

    public func withFavorite(_ isFavorite: Bool) -> UserItemData {
        UserItemData(
            played: played,
            playbackPositionTicks: playbackPositionTicks,
            playCount: playCount,
            isFavorite: isFavorite
        )
    }

    /// Same item, adopting the played-owned fields (`played`, `playbackPositionTicks`,
    /// `playCount`) from `payload` while keeping `self.isFavorite` — the played-operation
    /// counterpart to `withFavorite`. A played-operation server response's `isFavorite` is a
    /// DTO-boundary default (an absent field mapped to `false`), not real state, so it must
    /// never overwrite the existing favorite flag.
    public func withPlayed(from payload: UserItemData) -> UserItemData {
        UserItemData(
            played: payload.played,
            playbackPositionTicks: payload.playbackPositionTicks,
            playCount: payload.playCount,
            isFavorite: isFavorite
        )
    }
}
