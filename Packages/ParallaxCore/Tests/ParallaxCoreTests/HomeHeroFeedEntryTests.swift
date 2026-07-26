import Foundation
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxCore

@Suite("HomeHeroFeedEntry")
struct HomeHeroFeedEntryTests {
    private let inProgress = LibraryFixtures.userData(positionTicks: LibraryFixtures.ticks(minutes: 5))

    private func entry(presentation: Item, playTarget: Item) -> HomeHeroFeedEntry {
        HomeHeroFeedEntry(presentation: presentation, playTarget: playTarget, eyebrow: .newlyAdded)
    }

    /// The hero presents a SERIES but plays an EPISODE, so the entry's identity has to follow the
    /// thing on screen — keying it off the play target would make two shelves for one show.
    @Test("identity follows the presented item, not the play target")
    func idFollowsPresentation() {
        let series = Item.series(LibraryFixtures.series(id: "show"))
        let episode = Item.episode(LibraryFixtures.episode(id: "ep"))
        #expect(entry(presentation: series, playTarget: episode).id == ItemID(rawValue: "show"))
    }

    @Test("an untouched target reads Play, whatever its kind", arguments: [
        Item.movie(LibraryFixtures.movie()),
        .series(LibraryFixtures.series()),
        .episode(LibraryFixtures.episode()),
    ])
    func unstartedTargetsSayPlay(target: Item) {
        #expect(HomeHeroFeedEntry.playButtonTitle(for: target) == "Play")
    }

    /// The resume label names the episode so the button says what it will actually start —
    /// "Resume" alone reads ambiguously on a series hero.
    @Test("a part-watched episode names the episode it resumes")
    func resumeNamesTheEpisode() {
        let target = Item.episode(LibraryFixtures.episode(
            indexNumber: 4, parentIndexNumber: 2, userData: inProgress
        ))
        #expect(HomeHeroFeedEntry.playButtonTitle(for: target) == "Resume S2 E4")
    }

    @Test("an episode with unknown indices falls back to a bare Resume", arguments: [
        (nil, 4), (2, nil), (nil, nil),
    ] as [(Int?, Int?)])
    func resumeWithoutIndices(season: Int?, index: Int?) {
        let target = Item.episode(LibraryFixtures.episode(
            indexNumber: index, parentIndexNumber: season, userData: inProgress
        ))
        #expect(HomeHeroFeedEntry.playButtonTitle(for: target) == "Resume")
    }

    @Test("a part-watched movie resumes without a label")
    func resumeMovie() {
        let target = Item.movie(LibraryFixtures.movie(userData: inProgress))
        #expect(HomeHeroFeedEntry.playButtonTitle(for: target) == "Resume")
    }

    /// A series' own user data can carry position ticks, but a folder isn't resumable — the
    /// button has to read Play or it promises something the play target can't deliver.
    @Test("a series never says Resume, even carrying position ticks")
    func seriesNeverResumes() {
        let target = Item.series(LibraryFixtures.series(userData: inProgress))
        #expect(HomeHeroFeedEntry.playButtonTitle(for: target) == "Play")
    }

    /// A played item with stale ticks isn't in progress, so it starts over.
    @Test("a played target says Play despite leftover position ticks")
    func playedTargetSaysPlay() {
        let stale = LibraryFixtures.userData(played: true, positionTicks: LibraryFixtures.ticks(minutes: 5))
        let target = Item.episode(LibraryFixtures.episode(userData: stale))
        #expect(HomeHeroFeedEntry.playButtonTitle(for: target) == "Play")
    }

    @Test("the instance property agrees with the static derivation")
    func instancePropertyMatchesStatic() {
        let target = Item.movie(LibraryFixtures.movie(userData: inProgress))
        let entry = entry(presentation: .series(LibraryFixtures.series()), playTarget: target)
        #expect(entry.playButtonTitle == HomeHeroFeedEntry.playButtonTitle(for: target))
        #expect(entry.playButtonTitle == "Resume")
    }
}

@Suite("HeroEyebrow")
struct HeroEyebrowTests {
    /// The raw values ARE the rendered copy — the eyebrow is drawn straight from them.
    @Test("each eyebrow's raw value is the label it renders")
    func rawValuesAreTheCopy() {
        #expect(HeroEyebrow.newlyAdded.rawValue == "NEWLY ADDED")
        #expect(HeroEyebrow.newEpisodeAvailable.rawValue == "NEW EPISODE AVAILABLE")
    }
}
