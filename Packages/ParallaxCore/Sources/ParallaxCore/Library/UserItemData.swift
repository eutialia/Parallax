import Foundation

public struct UserItemData: Sendable, Hashable, Codable {
    /// `private(set) var` rather than `let` so the copy helpers below can mutate a copy instead of
    /// re-initializing with a hand-written field list — the pattern that silently zeroed fields
    /// whenever one was added and a call site forgot it. Immutable to callers either way.
    public private(set) var played: Bool
    public private(set) var playbackPositionTicks: Int64
    public private(set) var playCount: Int
    public private(set) var isFavorite: Bool
    /// When the server last recorded playback of this item. The ONE key that makes Continue
    /// Watching mergeable across servers: each Jellyfin server returns its own list already sorted
    /// by play date, and without a timestamp two such lists can only be concatenated ("server A's
    /// stale items, then server B's fresh ones"), never interleaved. Optional because it's absent
    /// for never-played items and for sources that don't track it.
    public private(set) var lastPlayedDate: Date?

    public init(
        played: Bool,
        playbackPositionTicks: Int64,
        playCount: Int,
        isFavorite: Bool,
        lastPlayedDate: Date? = nil
    ) {
        self.played = played
        self.playbackPositionTicks = playbackPositionTicks
        self.playCount = playCount
        self.isFavorite = isFavorite
        self.lastPlayedDate = lastPlayedDate
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
        var copy = self
        copy.isFavorite = isFavorite
        return copy
    }

    /// Same item, adopting the played-owned fields (`played`, `playbackPositionTicks`,
    /// `playCount`) from `payload` while keeping `self.isFavorite` — the played-operation
    /// counterpart to `withFavorite`. A played-operation server response's `isFavorite` is a
    /// DTO-boundary default (an absent field mapped to `false`), not real state, so it must
    /// never overwrite the existing favorite flag.
    public func withPlayed(from payload: UserItemData) -> UserItemData {
        var copy = self
        copy.played = payload.played
        copy.playbackPositionTicks = payload.playbackPositionTicks
        copy.playCount = payload.playCount
        // `lastPlayedDate` is played-owned too: marking something watched moves it, and Continue
        // Watching orders on it, so a patch that kept the stale date would sort the item wrong.
        copy.lastPlayedDate = payload.lastPlayedDate
        return copy
    }
}
