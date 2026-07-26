import Foundation
import ParallaxCore

/// Deterministic library-model fixtures.
///
/// One builder per model, every parameter defaulted, so a test names only the field it is
/// actually about — the alternative is re-typing a fifteen-argument memberwise init in every
/// suite, which is how a new field silently gets left out of half of them.
public enum LibraryFixtures {
    /// Jellyfin playback positions are in 100-nanosecond ticks.
    public static let ticksPerSecond: Int64 = 10_000_000

    public static func ticks(seconds: Int) -> Int64 { Int64(seconds) * ticksPerSecond }
    public static func ticks(minutes: Int) -> Int64 { ticks(seconds: minutes * 60) }

    public static func userData(
        played: Bool = false,
        positionTicks: Int64 = 0,
        playCount: Int = 0,
        isFavorite: Bool = false,
        lastPlayedDate: Date? = nil
    ) -> UserItemData {
        UserItemData(
            played: played,
            playbackPositionTicks: positionTicks,
            playCount: playCount,
            isFavorite: isFavorite,
            lastPlayedDate: lastPlayedDate
        )
    }

    public static func movie(
        id: String = "movie-1",
        title: String = "Inception",
        overview: String? = "A thief who steals corporate secrets.",
        year: Int? = 2010,
        runtime: Duration? = .seconds(148 * 60),
        communityRating: Double? = 8.8,
        officialRating: String? = "PG-13",
        genres: [String] = ["Action", "Sci-Fi"],
        primaryTag: ImageTag? = ImageTag(rawValue: "primary-tag"),
        backdropTags: [ImageTag] = [ImageTag(rawValue: "backdrop-0"), ImageTag(rawValue: "backdrop-1")],
        logoTag: ImageTag? = nil,
        thumbTag: ImageTag? = nil,
        dateAdded: Date? = nil,
        userData: UserItemData = LibraryFixtures.userData(),
        width: Int? = nil,
        height: Int? = nil,
        videoRangeType: String? = nil,
        hasSubtitles: Bool = false,
        size: Int64? = nil,
        blurHashes: [ImageTag: String] = [:]
    ) -> Movie {
        Movie(
            id: ItemID(rawValue: id), title: title, overview: overview, year: year,
            runtime: runtime, communityRating: communityRating, officialRating: officialRating,
            genres: genres, primaryTag: primaryTag, backdropTags: backdropTags,
            logoTag: logoTag, thumbTag: thumbTag, dateAdded: dateAdded, userData: userData,
            width: width, height: height, videoRangeType: videoRangeType,
            hasSubtitles: hasSubtitles, size: size, blurHashes: blurHashes
        )
    }

    public static func series(
        id: String = "series-1",
        title: String = "Breaking Bad",
        overview: String? = "A chemistry teacher turns to crime.",
        year: Int? = 2008,
        status: String? = "Ended",
        communityRating: Double? = 9.5,
        officialRating: String? = "TV-MA",
        genres: [String] = ["Drama"],
        primaryTag: ImageTag? = ImageTag(rawValue: "series-primary"),
        backdropTags: [ImageTag] = [ImageTag(rawValue: "series-backdrop-0")],
        logoTag: ImageTag? = nil,
        thumbTag: ImageTag? = nil,
        bannerTag: ImageTag? = nil,
        dateAdded: Date? = nil,
        userData: UserItemData = LibraryFixtures.userData(),
        blurHashes: [ImageTag: String] = [:]
    ) -> Series {
        Series(
            id: ItemID(rawValue: id), title: title, overview: overview, year: year,
            status: status, communityRating: communityRating, officialRating: officialRating,
            genres: genres, primaryTag: primaryTag, backdropTags: backdropTags,
            logoTag: logoTag, thumbTag: thumbTag, bannerTag: bannerTag,
            dateAdded: dateAdded, userData: userData, blurHashes: blurHashes
        )
    }

    public static func season(
        id: String = "season-1",
        seriesID: String = "series-1",
        name: String = "Season 1",
        indexNumber: Int? = 1,
        primaryTag: ImageTag? = ImageTag(rawValue: "season-primary"),
        thumbTag: ImageTag? = nil,
        episodeCount: Int? = 7,
        blurHashes: [ImageTag: String] = [:]
    ) -> Season {
        Season(
            id: ItemID(rawValue: id), seriesID: ItemID(rawValue: seriesID), name: name,
            indexNumber: indexNumber, primaryTag: primaryTag, thumbTag: thumbTag,
            episodeCount: episodeCount, blurHashes: blurHashes
        )
    }

    public static func episode(
        id: String = "episode-1",
        seriesID: String = "series-1",
        seasonID: String = "season-1",
        name: String = "Pilot",
        seriesName: String? = "Breaking Bad",
        indexNumber: Int? = 1,
        parentIndexNumber: Int? = 1,
        overview: String? = "The one where it starts.",
        runtime: Duration? = .seconds(45 * 60),
        primaryTag: ImageTag? = ImageTag(rawValue: "episode-primary"),
        seasonImageRef: ImageRef? = nil,
        seriesImageRef: ImageRef? = nil,
        dateAdded: Date? = nil,
        userData: UserItemData = LibraryFixtures.userData(),
        blurHashes: [ImageTag: String] = [:]
    ) -> Episode {
        Episode(
            id: ItemID(rawValue: id), seriesID: ItemID(rawValue: seriesID),
            seasonID: ItemID(rawValue: seasonID), name: name, seriesName: seriesName,
            indexNumber: indexNumber, parentIndexNumber: parentIndexNumber,
            overview: overview, runtime: runtime, primaryTag: primaryTag,
            seasonImageRef: seasonImageRef, seriesImageRef: seriesImageRef,
            dateAdded: dateAdded, userData: userData, blurHashes: blurHashes
        )
    }

    public static func collection(
        id: String = "collection-1",
        name: String = "Movies",
        collectionType: CollectionType = .movies,
        primaryTag: ImageTag? = ImageTag(rawValue: "collection-primary"),
        blurHashes: [ImageTag: String] = [:]
    ) -> MediaCollection {
        MediaCollection(
            id: CollectionID(rawValue: id), name: name, collectionType: collectionType,
            primaryTag: primaryTag, blurHashes: blurHashes
        )
    }

    public static func imageRef(
        itemID: String = "item-1",
        kind: ImageKind = .primary,
        tag: String = "tag",
        blurHash: String? = nil
    ) -> ImageRef {
        ImageRef(itemID: ItemID(rawValue: itemID), kind: kind, tag: ImageTag(rawValue: tag), blurHash: blurHash)
    }
}
