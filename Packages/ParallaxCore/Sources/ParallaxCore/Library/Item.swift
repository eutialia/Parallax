import Foundation

public enum Item: Sendable, Hashable, Identifiable {
    case movie(Movie)
    case series(Series)
    case episode(Episode)

    public var id: ItemID {
        switch self {
        case .movie(let m): return m.id
        case .series(let s): return s.id
        case .episode(let e): return e.id
        }
    }

    public var displayTitle: String {
        switch self {
        case .movie(let m): return m.title
        case .series(let s): return s.title
        case .episode(let e): return e.name
        }
    }

    public var overview: String? {
        switch self {
        case .movie(let m): return m.overview
        case .series(let s): return s.overview
        case .episode(let e): return e.overview
        }
    }

    public var runtime: Duration? {
        switch self {
        case .movie(let m): return m.runtime
        case .series: return nil
        case .episode(let e): return e.runtime
        }
    }

    /// Total source file size in bytes, when known. Populated for file-source (SMB) items from the
    /// directory listing; nil for server (Jellyfin) items, which carry a real `runtime` instead.
    public var sizeBytes: Int64? {
        switch self {
        case .movie(let m): return m.size
        case .series, .episode: return nil
        }
    }

    public var userData: UserItemData {
        switch self {
        case .movie(let m): return m.userData
        case .series(let s): return s.userData
        case .episode(let e): return e.userData
        }
    }

    /// Watched fraction for tile badges; nil when playback hasn't started or the
    /// runtime is unknown (series have no single runtime, so always nil there).
    public var playbackProgress: Double? {
        userData.playedFraction(runtime: runtime)
    }

    /// Delegates to the models' own mutated-copy `withUserData` — this used to re-init each model
    /// listing every field by hand, and silently reset any field the list forgot (blurHashes
    /// shipped broken that way: a Favorite toggle stripped every hash until a full reload).
    public func withUserData(_ userData: UserItemData) -> Item {
        switch self {
        case .movie(let m): return .movie(m.withUserData(userData))
        case .series(let s): return .series(s.withUserData(userData))
        case .episode(let e): return .episode(e.withUserData(userData))
        }
    }

    public func withFavorite(_ isFavorite: Bool) -> Item {
        withUserData(userData.withFavorite(isFavorite))
    }

    public func withSeasonImageRef(_ seasonImageRef: ImageRef?) -> Item {
        switch self {
        case .movie, .series: return self
        case .episode(let e): return .episode(e.withSeasonImageRef(seasonImageRef))
        }
    }

    public func withSeriesImageRef(_ seriesImageRef: ImageRef?) -> Item {
        switch self {
        case .movie, .series: return self
        case .episode(let e): return .episode(e.withSeriesImageRef(seriesImageRef))
        }
    }
}
