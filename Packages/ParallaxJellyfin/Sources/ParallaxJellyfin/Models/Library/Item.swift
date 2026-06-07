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

    public var userData: UserItemData {
        switch self {
        case .movie(let m): return m.userData
        case .series(let s): return s.userData
        case .episode(let e): return e.userData
        }
    }

    public func withUserData(_ userData: UserItemData) -> Item {
        switch self {
        case .movie(let m):
            return .movie(Movie(
                id: m.id, title: m.title, overview: m.overview, year: m.year, runtime: m.runtime,
                communityRating: m.communityRating, officialRating: m.officialRating, genres: m.genres,
                primaryTag: m.primaryTag, backdropTags: m.backdropTags, logoTag: m.logoTag, thumbTag: m.thumbTag,
                dateAdded: m.dateAdded,
                userData: userData, width: m.width, height: m.height, videoRangeType: m.videoRangeType
            ))
        case .series(let s):
            return .series(Series(
                id: s.id, title: s.title, overview: s.overview, year: s.year, status: s.status,
                genres: s.genres, primaryTag: s.primaryTag, backdropTags: s.backdropTags,
                logoTag: s.logoTag, thumbTag: s.thumbTag, bannerTag: s.bannerTag,
                dateAdded: s.dateAdded,
                userData: userData,
                width: s.width, height: s.height, videoRangeType: s.videoRangeType
            ))
        case .episode(let e):
            return .episode(Episode(
                id: e.id, seriesID: e.seriesID, seasonID: e.seasonID, name: e.name,
                indexNumber: e.indexNumber, parentIndexNumber: e.parentIndexNumber,
                overview: e.overview, runtime: e.runtime, primaryTag: e.primaryTag,
                seasonImageRef: e.seasonImageRef, seriesImageRef: e.seriesImageRef,
                dateAdded: e.dateAdded,
                userData: userData
            ))
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
