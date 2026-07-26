import Foundation
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxCore

@Suite("QualityBadge")
struct QualityBadgeTests {
    /// 4K is the only bucket the app labels — 1080p and below are the unremarkable default, and
    /// a badge on every tile would be noise. Either dimension can carry the signal, because a
    /// scope-ratio master is short on height and a vertical crop is short on width.
    @Test("resolution labels 4K from either dimension", arguments: [
        (3840, 2160, "4K"),
        (3840, 1600, "4K"),      // 2.40:1 scope master — height alone wouldn't qualify
        (2000, 2000, "4K"),      // tall crop — width alone wouldn't qualify
        (1920, 1080, nil),
        (1280, 720, nil),
    ] as [(Int?, Int?, String?)])
    func resolution(width: Int?, height: Int?, expected: String?) {
        #expect(QualityBadge.resolution(width: width, height: height) == expected)
    }

    /// A missing dimension reads as zero rather than disqualifying the item: a half-populated
    /// stream record still gets its badge from whichever side the server did report.
    @Test("a missing dimension is judged on the one that is known", arguments: [
        (nil, nil, nil),
        (nil, 1080, nil),
        (nil, 2160, "4K"),
        (3840, nil, "4K"),
        (1920, nil, nil),
    ] as [(Int?, Int?, String?)])
    func resolutionWithMissingDimension(width: Int?, height: Int?, expected: String?) {
        #expect(QualityBadge.resolution(width: width, height: height) == expected)
    }

    /// Every HDR flavour collapses to one label — including `DOVIInvalid`, whose corrupt Dolby
    /// Vision metadata AVKit cannot deliver as DV.
    @Test("all HDR flavours collapse to a single label", arguments: [
        "HDR10", "hdr10", "HDR10Plus", "DOVI", "DOVIWithHDR10", "DOVIInvalid",
        "DolbyVision", "HLG",
    ])
    func hdrFlavours(videoRangeType: String) {
        #expect(QualityBadge.hdr(videoRangeType) == "HDR")
    }

    @Test("SDR and unknown ranges carry no HDR label", arguments: ["SDR", "", "Unknown", nil] as [String?])
    func hdrAbsent(videoRangeType: String?) {
        #expect(QualityBadge.hdr(videoRangeType) == nil)
    }

    @Test("badges list the resolution before the HDR label")
    func badgeOrder() {
        #expect(QualityBadge.badges(width: 3840, height: 2160, videoRangeType: "DOVI") == ["4K", "HDR"])
        #expect(QualityBadge.badges(width: 1920, height: 1080, videoRangeType: "HDR10") == ["HDR"])
        #expect(QualityBadge.badges(width: 3840, height: 2160, videoRangeType: "SDR") == ["4K"])
        #expect(QualityBadge.badges(width: 1920, height: 1080, videoRangeType: "SDR").isEmpty)
    }
}

@Suite("DetailMetadata")
struct DetailMetadataTests {
    @Test("a movie's hero line reads year, runtime, rating, certificate")
    func movieTextParts() {
        let metadata = DetailMetadata(movie: LibraryFixtures.movie(
            year: 2010, runtime: .seconds(148 * 60), communityRating: 8.8, officialRating: "PG-13"
        ))
        #expect(metadata.textParts == ["2010", "148 min", "★ 8.8", "PG-13"])
    }

    @Test("unknown movie facts drop out of the line rather than rendering blanks")
    func movieTextPartsCompacted() {
        let metadata = DetailMetadata(movie: LibraryFixtures.movie(
            year: nil, runtime: nil, communityRating: nil, officialRating: nil
        ))
        #expect(metadata.textParts.isEmpty)
    }

    /// A blank certificate string is as absent as a nil one — the server sends "" for
    /// unrated items on some libraries.
    @Test("an empty string is filtered out like a missing value")
    func emptyStringsAreFiltered() {
        let metadata = DetailMetadata(movie: LibraryFixtures.movie(
            year: 2010, runtime: nil, communityRating: nil, officialRating: ""
        ))
        #expect(metadata.textParts == ["2010"])
    }

    /// A near-zero runtime means "not scanned yet", not "a zero-minute film".
    @Test("a sub-minute runtime is omitted rather than rendered as 0 min")
    func subMinuteRuntimeOmitted() {
        let metadata = DetailMetadata(movie: LibraryFixtures.movie(
            year: nil, runtime: .seconds(30), communityRating: nil, officialRating: nil
        ))
        #expect(metadata.textParts.isEmpty)
    }

    @Test("the community rating renders to one decimal behind a star")
    func communityRatingFormat() {
        let metadata = DetailMetadata(movie: LibraryFixtures.movie(
            year: nil, runtime: nil, communityRating: 7.26, officialRating: nil
        ))
        #expect(metadata.textParts == ["★ 7.3"])
    }

    @Test("a movie's quality badges come from its own stream dimensions and range")
    func movieQualityBadges() {
        let metadata = DetailMetadata(movie: LibraryFixtures.movie(
            width: 3840, height: 2160, videoRangeType: "DOVI", hasSubtitles: true
        ))
        #expect(metadata.qualityLabels == ["4K", "HDR"])
        #expect(metadata.hasSubtitles)
    }

    /// Series are Jellyfin folders: quality and subtitles live on the episodes, so the series
    /// hero must not claim either.
    @Test("a series' hero line reads year, status, rating, certificate — and carries no quality")
    func seriesTextParts() {
        let metadata = DetailMetadata(series: LibraryFixtures.series(
            year: 2008, status: "Ended", communityRating: 9.5, officialRating: "TV-MA"
        ))
        #expect(metadata.textParts == ["2008", "Ended", "★ 9.5", "TV-MA"])
        #expect(metadata.qualityLabels.isEmpty)
        #expect(metadata.hasSubtitles == false)
    }

    @Test("unknown series facts drop out too")
    func seriesTextPartsCompacted() {
        let metadata = DetailMetadata(series: LibraryFixtures.series(
            year: nil, status: nil, communityRating: nil, officialRating: nil
        ))
        #expect(metadata.textParts.isEmpty)
    }

    /// `isEmpty` is what the hero uses to skip the whole metadata row, so a lone subtitle badge
    /// must still count as content.
    @Test("isEmpty is true only when there is no text, no badge and no subtitle mark", arguments: [
        ([], [], false, true),
        (["2010"], [], false, false),
        ([], ["4K"], false, false),
        ([], [], true, false),
    ] as [([String], [String], Bool, Bool)])
    func isEmpty(textParts: [String], qualityLabels: [String], hasSubtitles: Bool, expected: Bool) {
        let metadata = DetailMetadata(
            textParts: textParts, qualityLabels: qualityLabels, hasSubtitles: hasSubtitles
        )
        #expect(metadata.isEmpty == expected)
    }
}
