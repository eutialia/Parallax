import Foundation
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxCore

@Suite("Item")
struct ItemTests {
    private let movie = LibraryFixtures.movie()
    private let series = LibraryFixtures.series()
    private let episode = LibraryFixtures.episode()

    @Test("id forwards to the wrapped model")
    func id() {
        #expect(Item.movie(movie).id == movie.id)
        #expect(Item.series(series).id == series.id)
        #expect(Item.episode(episode).id == episode.id)
    }

    /// The display title is the per-case naming difference the enum exists to smooth over:
    /// movies and series carry `title`, episodes carry `name`.
    @Test("display title reads each case's own naming field")
    func displayTitle() {
        #expect(Item.movie(movie).displayTitle == movie.title)
        #expect(Item.series(series).displayTitle == series.title)
        #expect(Item.episode(episode).displayTitle == episode.name)
    }

    @Test("overview forwards to the wrapped model")
    func overview() {
        #expect(Item.movie(movie).overview == movie.overview)
        #expect(Item.series(series).overview == series.overview)
        #expect(Item.episode(episode).overview == episode.overview)
    }

    /// A series is a folder — it has no single runtime, and claiming one would give every
    /// series tile a bogus progress bar.
    @Test("runtime is nil for a series and forwarded for playable items")
    func runtime() {
        #expect(Item.movie(movie).runtime == movie.runtime)
        #expect(Item.episode(episode).runtime == episode.runtime)
        #expect(Item.series(series).runtime == nil)
    }

    /// File size is a file-source (SMB) fact; server items carry a real runtime instead.
    @Test("size is only carried by a movie, and only when the source knows it")
    func sizeBytes() {
        #expect(Item.movie(LibraryFixtures.movie(size: 4_294_967_296)).sizeBytes == 4_294_967_296)
        #expect(Item.movie(LibraryFixtures.movie(size: nil)).sizeBytes == nil)
        #expect(Item.series(series).sizeBytes == nil)
        #expect(Item.episode(episode).sizeBytes == nil)
    }

    @Test("user data forwards to the wrapped model")
    func userData() {
        let watched = LibraryFixtures.userData(played: true, playCount: 2)
        #expect(Item.movie(LibraryFixtures.movie(userData: watched)).userData == watched)
        #expect(Item.series(LibraryFixtures.series(userData: watched)).userData == watched)
        #expect(Item.episode(LibraryFixtures.episode(userData: watched)).userData == watched)
    }

    @Test("playback progress divides the position by the item's own runtime")
    func playbackProgress() {
        let halfway = LibraryFixtures.userData(positionTicks: LibraryFixtures.ticks(seconds: 50))
        let item = Item.movie(LibraryFixtures.movie(runtime: .seconds(100), userData: halfway))
        #expect(item.playbackProgress == 0.5)
    }

    @Test("a series never reports playback progress — it has no runtime to divide by")
    func playbackProgressSeries() {
        let started = LibraryFixtures.userData(positionTicks: LibraryFixtures.ticks(seconds: 50))
        #expect(Item.series(LibraryFixtures.series(userData: started)).playbackProgress == nil)
    }

    /// This delegation used to re-init each model by hand and silently reset whatever field the
    /// list forgot — a Favorite toggle stripped every BlurHash until a full reload.
    @Test("withUserData keeps the wrapped model's other fields intact")
    func withUserDataPreservesBlurHashes() {
        let tag = ImageTag(rawValue: "poster")
        let hashes = [tag: "LKO2?U"]
        let cases: [Item] = [
            .movie(LibraryFixtures.movie(primaryTag: tag, blurHashes: hashes)),
            .series(LibraryFixtures.series(primaryTag: tag, blurHashes: hashes)),
            .episode(LibraryFixtures.episode(primaryTag: tag, blurHashes: hashes)),
        ]

        for item in cases {
            let updated = item.withUserData(LibraryFixtures.userData(played: true))
            #expect(updated.userData.played)
            #expect(updated.id == item.id)
            #expect(updated.withUserData(item.userData) == item, "the copy must be reversible")
        }
    }

    @Test("withFavorite flips only the favorite flag")
    func withFavorite() {
        let item = Item.movie(LibraryFixtures.movie(
            userData: LibraryFixtures.userData(played: true, playCount: 3)
        ))

        let favorited = item.withFavorite(true)
        #expect(favorited.userData.isFavorite)
        #expect(favorited.userData.played)
        #expect(favorited.userData.playCount == 3)
        #expect(favorited.withFavorite(false) == item)
    }

    /// Parent artwork only exists for episodes; a movie or series must pass through untouched
    /// rather than acquiring an unrelated ref.
    @Test("parent-artwork copies apply to episodes only")
    func parentArtworkCopiesApplyToEpisodesOnly() throws {
        let ref = LibraryFixtures.imageRef(tag: "season")

        let movieItem = Item.movie(movie)
        #expect(movieItem.withSeasonImageRef(ref) == movieItem)
        #expect(movieItem.withSeriesImageRef(ref) == movieItem)

        let seriesItem = Item.series(series)
        #expect(seriesItem.withSeasonImageRef(ref) == seriesItem)
        #expect(seriesItem.withSeriesImageRef(ref) == seriesItem)

        guard case .episode(let withSeason) = Item.episode(episode).withSeasonImageRef(ref) else {
            Issue.record("expected an episode back")
            return
        }
        #expect(withSeason.seasonImageRef == ref)

        guard case .episode(let withSeries) = Item.episode(episode).withSeriesImageRef(ref) else {
            Issue.record("expected an episode back")
            return
        }
        #expect(withSeries.seriesImageRef == ref)
    }
}
