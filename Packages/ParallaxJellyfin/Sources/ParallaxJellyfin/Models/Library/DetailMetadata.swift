import Foundation

/// Text + badge metadata shown in the hero on movie/series detail screens.
public struct DetailMetadata: Sendable, Hashable {
    public let textParts: [String]
    public let qualityLabels: [String]
    public let hasSubtitles: Bool

    public var isEmpty: Bool {
        textParts.isEmpty && qualityLabels.isEmpty && !hasSubtitles
    }

    public init(textParts: [String], qualityLabels: [String], hasSubtitles: Bool) {
        self.textParts = textParts
        self.qualityLabels = qualityLabels
        self.hasSubtitles = hasSubtitles
    }

    public init(movie: Movie) {
        self = Self.make(
            textParts: [
                Self.year(movie.year),
                Self.runtime(movie.runtime),
                Self.communityRating(movie.communityRating),
                movie.officialRating,
            ],
            qualityWidth: movie.width,
            qualityHeight: movie.height,
            videoRangeType: movie.videoRangeType,
            hasSubtitles: movie.hasSubtitles
        )
    }

    /// Series are Jellyfin folders — quality and subtitles live on episodes, not the series item.
    public init(series: Series) {
        self.init(
            textParts: Self.compactTextParts([
                Self.year(series.year),
                series.status,
                Self.communityRating(series.communityRating),
                series.officialRating,
            ]),
            qualityLabels: [],
            hasSubtitles: false
        )
    }

    private static func make(
        textParts: [String?],
        qualityWidth: Int?,
        qualityHeight: Int?,
        videoRangeType: String?,
        hasSubtitles: Bool
    ) -> DetailMetadata {
        DetailMetadata(
            textParts: Self.compactTextParts(textParts),
            qualityLabels: QualityBadge.badges(
                width: qualityWidth, height: qualityHeight, videoRangeType: videoRangeType
            ),
            hasSubtitles: hasSubtitles
        )
    }

    private static func compactTextParts(_ parts: [String?]) -> [String] {
        parts.compactMap { $0 }.filter { !$0.isEmpty }
    }

    private static func year(_ year: Int?) -> String? {
        year.map(String.init)
    }

    private static func runtime(_ runtime: Duration?) -> String? {
        guard let runtime else { return nil }
        let mins = Int(runtime.components.seconds / 60)
        guard mins > 0 else { return nil }
        return "\(mins) min"
    }

    private static func communityRating(_ rating: Double?) -> String? {
        guard let rating else { return nil }
        return String(format: "★ %.1f", rating)
    }
}
