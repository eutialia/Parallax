import Foundation
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxCore

@Suite("Episode captions")
struct EpisodeCaptionTests {
    /// The app's middle-dot house style — "S1 · E2", never "S1, E2".
    @Test("season/episode label uses the middle-dot separator")
    func seasonEpisodeLabel() {
        let episode = LibraryFixtures.episode(indexNumber: 2, parentIndexNumber: 1)
        #expect(episode.seasonEpisodeLabel == "S1 · E2")
    }

    @Test("the label needs BOTH indices; either one missing yields nil", arguments: [
        (nil, 2), (1, nil), (nil, nil),
    ] as [(Int?, Int?)])
    func seasonEpisodeLabelNeedsBothIndices(season: Int?, index: Int?) {
        let episode = LibraryFixtures.episode(indexNumber: index, parentIndexNumber: season)
        #expect(episode.seasonEpisodeLabel == nil)
    }

    /// The index caption degrades one step at a time: full label → bare episode → nothing.
    @Test("index caption degrades gracefully as indices go missing", arguments: [
        (1, 2, "S1 · E2"),
        (nil, 2, "E2"),          // season unknown (a special, an unnumbered extra)
        (0, 3, "S0 · E3"),       // season 0 is the specials season, not "missing"
    ] as [(Int?, Int?, String)])
    func indexCaption(season: Int?, index: Int?, expected: String) {
        let episode = LibraryFixtures.episode(indexNumber: index, parentIndexNumber: season)
        #expect(episode.indexCaption == expected)
    }

    @Test("no episode index means no index caption at all")
    func indexCaptionNil() {
        #expect(LibraryFixtures.episode(indexNumber: nil, parentIndexNumber: 1).indexCaption == nil)
    }

    /// Index first so tail truncation in a tight row eats the show name, never the position.
    @Test("cross-series caption puts the index before the series name")
    func seriesContextCaption() {
        let episode = LibraryFixtures.episode(
            seriesName: "Breaking Bad", indexNumber: 2, parentIndexNumber: 1
        )
        #expect(episode.seriesContextCaption == "S1 · E2 · Breaking Bad")
    }

    /// An orphaned episode with a blank SeriesName must not render a dangling separator.
    @Test("empty or missing parts drop out of the cross-series caption without a dangling dot",
          arguments: ["", nil] as [String?])
    func seriesContextCaptionDropsBlankSeriesName(seriesName: String?) {
        let episode = LibraryFixtures.episode(
            seriesName: seriesName, indexNumber: 2, parentIndexNumber: 1
        )
        #expect(episode.seriesContextCaption == "S1 · E2")
    }

    @Test("a nameless, index-less episode has no cross-series caption at all")
    func seriesContextCaptionNil() {
        let episode = LibraryFixtures.episode(
            seriesName: nil, indexNumber: nil, parentIndexNumber: nil
        )
        #expect(episode.seriesContextCaption == nil)
    }

    @Test("only the series name survives when the indices are unknown")
    func seriesContextCaptionSeriesOnly() {
        let episode = LibraryFixtures.episode(
            seriesName: "Breaking Bad", indexNumber: nil, parentIndexNumber: nil
        )
        #expect(episode.seriesContextCaption == "Breaking Bad")
    }

    /// Inside a season row the season is already context, so this surface uses a list ordinal
    /// rather than the middle-dot caption.
    @Test("same-series caption is a numbered list entry, not the middle-dot caption")
    func indexedNameCaption() {
        let episode = LibraryFixtures.episode(name: "The One With the Embryos", indexNumber: 3)
        #expect(episode.indexedNameCaption == "3. The One With the Embryos")
    }

    @Test("a nameless episode falls back to its bare index, never a dangling \". \"")
    func indexedNameCaptionBlankName() {
        #expect(LibraryFixtures.episode(name: "", indexNumber: 3).indexedNameCaption == "E3")
    }

    @Test("an index-less episode falls back to its bare name")
    func indexedNameCaptionNoIndex() {
        let episode = LibraryFixtures.episode(name: "Special", indexNumber: nil)
        #expect(episode.indexedNameCaption == "Special")
    }
}

@Suite("Episode runtime and progress")
struct EpisodeRuntimeTests {
    @Test("runtime rounds down to whole minutes", arguments: [
        (45 * 60, 45), (45 * 60 + 59, 45), (60, 1),
    ])
    func runtimeLengthMinutes(seconds: Int, expected: Int) {
        #expect(LibraryFixtures.episode(runtime: .seconds(seconds)).runtimeLengthMinutes == expected)
    }

    /// A sub-minute runtime reports nothing rather than "0 min" — Jellyfin sometimes hands back
    /// a near-zero runtime for an item it hasn't finished scanning.
    @Test("a sub-minute or missing runtime reports no minutes", arguments: [0, 30, 59])
    func runtimeLengthMinutesTooShort(seconds: Int) {
        #expect(LibraryFixtures.episode(runtime: .seconds(seconds)).runtimeLengthMinutes == nil)
    }

    @Test("no runtime at all means no minutes")
    func runtimeLengthMinutesNilRuntime() {
        #expect(LibraryFixtures.episode(runtime: nil).runtimeLengthMinutes == nil)
    }

    @Test("an unstarted episode shows its full runtime")
    func timeCaptionUnwatched() {
        let episode = LibraryFixtures.episode(runtime: .seconds(45 * 60))
        #expect(episode.timeCaption() == "45 min")
    }

    @Test("a part-watched episode shows the time remaining instead")
    func timeCaptionInProgress() {
        let episode = LibraryFixtures.episode(
            runtime: .seconds(45 * 60),
            userData: LibraryFixtures.userData(positionTicks: LibraryFixtures.ticks(minutes: 23))
        )
        #expect(episode.timeCaption() == "22 min left")
    }

    /// A played episode never reports time left even when the server leaves stale position ticks
    /// behind — that would contradict the watched check drawn on the same tile.
    @Test("a played episode falls back to its runtime despite stale position ticks")
    func timeCaptionPlayedIgnoresStalePosition() {
        let episode = LibraryFixtures.episode(
            runtime: .seconds(45 * 60),
            userData: LibraryFixtures.userData(
                played: true, positionTicks: LibraryFixtures.ticks(minutes: 23)
            )
        )
        #expect(episode.timeCaption() == "45 min")
    }

    @Test("opting out of both facets yields no time caption")
    func timeCaptionFullyOptedOut() {
        let episode = LibraryFixtures.episode(
            runtime: .seconds(45 * 60),
            userData: LibraryFixtures.userData(positionTicks: LibraryFixtures.ticks(minutes: 23))
        )
        #expect(episode.timeCaption(showTimeRemaining: false, showRuntimeLength: false) == nil)
    }

    @Test("opting out of time-remaining falls back to the runtime")
    func timeCaptionRuntimeOnly() {
        let episode = LibraryFixtures.episode(
            runtime: .seconds(45 * 60),
            userData: LibraryFixtures.userData(positionTicks: LibraryFixtures.ticks(minutes: 23))
        )
        #expect(episode.timeCaption(showTimeRemaining: false) == "45 min")
    }

    @Test("shelf footer joins the index and the time metadata with middle dots")
    func shelfFooterCaption() {
        let unwatched = LibraryFixtures.episode(indexNumber: 2, parentIndexNumber: 1)
        #expect(unwatched.shelfFooterCaption() == "S1 · E2 · 45 min")

        let inProgress = LibraryFixtures.episode(
            indexNumber: 2, parentIndexNumber: 1,
            userData: LibraryFixtures.userData(positionTicks: LibraryFixtures.ticks(minutes: 23))
        )
        #expect(inProgress.shelfFooterCaption() == "S1 · E2 · 22 min left")
    }

    @Test("shelf footer drops to the index alone when there is no time to show")
    func shelfFooterCaptionIndexOnly() {
        let episode = LibraryFixtures.episode(indexNumber: 2, parentIndexNumber: 1, runtime: nil)
        #expect(episode.shelfFooterCaption() == "S1 · E2")
    }

    @Test("shelf footer is nil when neither the index nor the time is known")
    func shelfFooterCaptionNil() {
        let episode = LibraryFixtures.episode(
            indexNumber: nil, parentIndexNumber: nil, runtime: nil
        )
        #expect(episode.shelfFooterCaption() == nil)
    }

    @Test("shelf progress is the played fraction while mid-watch")
    func shelfPlaybackProgress() {
        let episode = LibraryFixtures.episode(
            runtime: .seconds(100),
            userData: LibraryFixtures.userData(positionTicks: LibraryFixtures.ticks(seconds: 25))
        )
        #expect(episode.shelfPlaybackProgress == 0.25)
    }

    /// A partial bar on a played episode would contradict the watched check the same surface
    /// draws, so the guard is on `played`, not merely on the position.
    @Test("a played episode reports no shelf progress, stale ticks or not")
    func shelfPlaybackProgressPlayed() {
        let episode = LibraryFixtures.episode(
            runtime: .seconds(100),
            userData: LibraryFixtures.userData(played: true, positionTicks: LibraryFixtures.ticks(seconds: 25))
        )
        #expect(episode.shelfPlaybackProgress == nil)
    }

    @Test("an unstarted episode reports no shelf progress")
    func shelfPlaybackProgressUnstarted() {
        #expect(LibraryFixtures.episode().shelfPlaybackProgress == nil)
    }

    @Test("an episode with no runtime reports no shelf progress")
    func shelfPlaybackProgressNoRuntime() {
        let episode = LibraryFixtures.episode(
            runtime: nil,
            userData: LibraryFixtures.userData(positionTicks: LibraryFixtures.ticks(seconds: 25))
        )
        #expect(episode.shelfPlaybackProgress == nil)
    }
}

@Suite("Episode artwork")
struct EpisodeArtworkTests {
    @Test("the primary ref carries the episode's own tag and its BlurHash")
    func primaryImageRef() throws {
        let tag = ImageTag(rawValue: "still")
        let episode = LibraryFixtures.episode(primaryTag: tag, blurHashes: [tag: "LKO2?U"])

        let ref = try #require(episode.imageRef(.primary))
        #expect(ref.itemID == episode.id)
        #expect(ref.tag == tag)
        #expect(ref.blurHash == "LKO2?U")
    }

    @Test("no primary tag means no primary ref")
    func primaryImageRefNil() {
        #expect(LibraryFixtures.episode(primaryTag: nil).imageRef(.primary) == nil)
    }

    /// An episode only ever carries its own still; every other kind belongs to a parent item.
    @Test("every non-primary image kind is absent on an episode", arguments: [
        ImageKind.backdrop(index: 0), .logo, .thumb, .banner, .art, .disc,
    ])
    func nonPrimaryKindsAreNil(kind: ImageKind) {
        #expect(LibraryFixtures.episode().imageRef(kind) == nil)
    }

    /// Landscape surfaces (search) want the 16:9 still first; a parent poster center-crops, which
    /// still beats an empty placeholder.
    @Test("still-first artwork prefers the episode's own still")
    func stillFirstPrefersOwnStill() throws {
        let episode = LibraryFixtures.episode(
            seasonImageRef: LibraryFixtures.imageRef(tag: "season"),
            seriesImageRef: LibraryFixtures.imageRef(tag: "series")
        )
        let ref = try #require(episode.stillFirstImageRef)
        #expect(ref.tag == ImageTag(rawValue: "episode-primary"))
    }

    @Test("still-first artwork falls back to season art, then series art")
    func stillFirstFallsBackThroughParents() throws {
        let seasonFallback = LibraryFixtures.episode(
            primaryTag: nil,
            seasonImageRef: LibraryFixtures.imageRef(tag: "season"),
            seriesImageRef: LibraryFixtures.imageRef(tag: "series")
        )
        #expect(seasonFallback.stillFirstImageRef?.tag == ImageTag(rawValue: "season"))

        let seriesFallback = LibraryFixtures.episode(
            primaryTag: nil, seriesImageRef: LibraryFixtures.imageRef(tag: "series")
        )
        #expect(seriesFallback.stillFirstImageRef?.tag == ImageTag(rawValue: "series"))

        #expect(LibraryFixtures.episode(primaryTag: nil).stillFirstImageRef == nil)
    }
}

@Suite("Episode copy helpers")
struct EpisodeCopyTests {
    /// These are mutated copies precisely BECAUSE a re-init listing every field once zeroed
    /// `blurHashes` on a Favorite toggle — so every copy helper is checked for the leak.
    @Test("withUserData keeps every other field, blurHashes included")
    func withUserDataPreservesFields() {
        let tag = ImageTag(rawValue: "still")
        let original = LibraryFixtures.episode(
            primaryTag: tag,
            seasonImageRef: LibraryFixtures.imageRef(tag: "season"),
            seriesImageRef: LibraryFixtures.imageRef(tag: "series"),
            blurHashes: [tag: "LKO2?U"]
        )

        let updated = original.withUserData(LibraryFixtures.userData(played: true, playCount: 1))

        #expect(updated.userData.played)
        #expect(updated.blurHashes == original.blurHashes)
        #expect(updated.seasonImageRef == original.seasonImageRef)
        #expect(updated.seriesImageRef == original.seriesImageRef)
        #expect(updated.withUserData(original.userData) == original)
    }

    @Test("withSeasonImageRef swaps only the season art")
    func withSeasonImageRef() {
        let original = LibraryFixtures.episode()
        let ref = LibraryFixtures.imageRef(tag: "season")

        let updated = original.withSeasonImageRef(ref)
        #expect(updated.seasonImageRef == ref)
        #expect(updated.withSeasonImageRef(nil) == original)
    }

    @Test("withSeriesImageRef swaps only the series art")
    func withSeriesImageRef() {
        let original = LibraryFixtures.episode()
        let ref = LibraryFixtures.imageRef(tag: "series")

        let updated = original.withSeriesImageRef(ref)
        #expect(updated.seriesImageRef == ref)
        #expect(updated.withSeriesImageRef(nil) == original)
    }
}
