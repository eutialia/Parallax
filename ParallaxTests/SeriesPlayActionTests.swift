import Testing
import ParallaxCore
@testable import Parallax

/// `SeriesPlayAction` is the pure core of the series-pill fix: it turns the series hero's two
/// former view branches ("Resume S# E#" / "Play" / nothing at all) into ONE value that always
/// carries a title and only optionally carries a target. The structural point is the first
/// case below — "nothing loaded yet" must still produce a titled action, because the pill that
/// renders it carries the hero action row's `prefersDefaultFocus` pin. No view, no view model,
/// no repository is involved here.
@Suite("SeriesPlayAction — the series hero's always-present play CTA")
struct SeriesPlayActionTests {

    /// One resolve input paired with what the row must show. `name` is the phase of the load
    /// it represents, which is also the case label in the test output.
    ///
    /// No `expectedAvailability` field: it's a FUNCTION of the target and the settled flag
    /// (`availability(settled:)` below), and spelling it per row would let a copy-paste assert
    /// the very confusion this type exists to prevent — a target-less action calling itself
    /// `.loading` after the load finished.
    struct Phase: Sendable, CustomTestStringConvertible {
        let name: String
        let resume: Episode?
        let first: Episode?
        let expectedTitle: String
        let expectedTarget: ItemID?

        var testDescription: String { name }

        func availability(settled: Bool) -> SeriesPlayAction.Availability {
            if let expectedTarget { .ready(expectedTarget) } else if settled { .unavailable } else { .loading }
        }
    }

    /// S1 E1, untouched — a fresh series' first episode, and the one shape
    /// `ItemPlayButtonLabel.shouldResumeSeries` deliberately calls "not a resume".
    private static let firstEpisode = makeEpisode("first-e1", seriesID: "ser", season: 1, index: 1)

    static let phases: [Phase] = [
        // THE regression case, and the one the settled axis splits in two. `load()` publishes
        // `.loaded` before the episode lists and the /Shows/NextUp target land, so this is what
        // the row resolves with on the very first laid-out frame — the frame tvOS resolves
        // default focus on. A nil action here means no pill, which means the pin has nothing to
        // pin and Favorite takes the landing for the rest of the screen's life. Unsettled it's
        // `.loading`; settled — a failed fetch, or a genuinely empty series — it's
        // `.unavailable`, and the pill must stop advertising a load that already ended.
        Phase(
            name: "no play target",
            resume: nil, first: nil,
            expectedTitle: "Play", expectedTarget: nil
        ),
        Phase(
            name: "never-watched series — no next-up, falls back to the first episode",
            resume: nil, first: firstEpisode,
            expectedTitle: "Play", expectedTarget: ItemID(rawValue: "first-e1")
        ),
        Phase(
            name: "next-up episode is mid-watch",
            resume: makeEpisode("nu", seriesID: "ser", season: 3, index: 4, positionTicks: 1_000),
            first: firstEpisode,
            expectedTitle: "Resume S3 E4", expectedTarget: ItemID(rawValue: "nu")
        ),
        Phase(
            name: "next-up episode is a later, untouched one — continuing the series",
            resume: makeEpisode("nu", seriesID: "ser", season: 2, index: 1),
            first: firstEpisode,
            expectedTitle: "Resume S2 E1", expectedTarget: ItemID(rawValue: "nu")
        ),
        // `shouldResumeSeries` is false here (untouched S1 E1), so the copy is a plain "Play" —
        // but the TARGET is still the next-up episode, not `first`. That precedence is the old
        // `resume ?? vm.firstEpisode` fallback, preserved verbatim; the two ids differ so a
        // regression to `first` would fail rather than accidentally agree.
        Phase(
            name: "next-up is the untouched first episode — plain Play, still aimed at next-up",
            resume: makeEpisode("nu-e1", seriesID: "ser", season: 1, index: 1),
            first: firstEpisode,
            expectedTitle: "Play", expectedTarget: ItemID(rawValue: "nu-e1")
        ),
        // Double-digit season AND episode — the widest copy this type can produce. The pill's
        // width reserve has to cover it, or a long-running series slides the Favorite disc the
        // first time the title swaps.
        Phase(
            name: "mid-watch next-up deep in a long-running series",
            resume: makeEpisode("nu", seriesID: "ser", season: 12, index: 34, positionTicks: 1_000),
            first: firstEpisode,
            expectedTitle: "Resume S12 E34", expectedTarget: ItemID(rawValue: "nu")
        ),
        // Jellyfin can hand back an episode with no season/episode numbering (specials, or a
        // library with broken metadata). The copy degrades to the bare verb rather than
        // rendering "Resume S E".
        Phase(
            name: "mid-watch next-up with no numbering",
            resume: makeEpisode("nu", seriesID: "ser", positionTicks: 1_000),
            first: firstEpisode,
            expectedTitle: "Resume", expectedTarget: ItemID(rawValue: "nu")
        ),
    ]

    /// Both halves of the settled axis, against every phase: a phase that resolves a target
    /// resolves the same one either way, and only the target-less phase splits.
    @Test("resolve maps each load phase to its title and availability",
          arguments: phases, [false, true])
    func resolvesPhase(phase: Phase, episodesSettled: Bool) {
        let action = SeriesPlayAction.resolve(resume: phase.resume,
                                              first: phase.first,
                                              episodesSettled: episodesSettled)
        #expect(action.title == phase.expectedTitle)
        #expect(action.target == phase.expectedTarget)
        #expect(action.isReady == (phase.expectedTarget != nil))
        #expect(action.availability == phase.availability(settled: episodesSettled))
    }

    /// The bug the third state exists for: a series whose episodes never arrive (fetch failed,
    /// or the series is empty) used to sit on `.loading` forever — an enabled, tappable no-op
    /// pill telling VoiceOver it was still loading episodes. The title stays "Play" in both:
    /// the pill has to keep rendering, because it carries the row's default-focus pin.
    @Test("a settled series with no episodes reads unavailable, not perpetually loading")
    func settledWithNoEpisodesIsUnavailable() {
        let loading = SeriesPlayAction.resolve(resume: nil, first: nil, episodesSettled: false)
        #expect(loading.availability == .loading)
        #expect(loading.accessibilityHint == "Loading episodes")
        #expect(loading.title == "Play")

        let settled = SeriesPlayAction.resolve(resume: nil, first: nil, episodesSettled: true)
        #expect(settled.availability == .unavailable)
        #expect(settled.accessibilityHint == "No episodes available")
        #expect(settled.title == "Play")
    }

    /// A ready action must say nothing extra — the hint is the ONLY signal that the pill is
    /// currently inert, so an empty one is load-bearing.
    @Test("a ready action carries no hint", arguments: phases.filter { $0.expectedTarget != nil })
    func readyActionHasNoHint(phase: Phase) {
        let action = SeriesPlayAction.resolve(resume: phase.resume, first: phase.first, episodesSettled: true)
        #expect(action.accessibilityHint.isEmpty)
    }

    /// `PrimaryPlayButton` reserves the pill's width with the SERIES reserve
    /// (`ItemPlayButtonLabel.layoutReserveTitle(for: .episodeNumbered)` — "Resume S99 E99"; movie
    /// detail reserves the narrower `.verbOnly`) so Play↔Resume can't reflow the row. That only
    /// holds while every title this type produces is one of the three shapes the reserve was
    /// measured against, and fits inside it.
    @Test("every title is a shape the pill's width reserve was designed for", arguments: phases)
    func titleFitsTheWidthReserve(phase: Phase) {
        let title = SeriesPlayAction.resolve(resume: phase.resume,
                                             first: phase.first,
                                             episodesSettled: true).title
        let isKnownShape = title == "Play"
            || title == "Resume"
            || title.wholeMatch(of: /Resume S\d+ E\d+/) != nil
        #expect(isKnownShape, "unrecognized play CTA shape: \(title)")
        #expect(title.count <= ItemPlayButtonLabel.layoutReserveTitle(for: .episodeNumbered).count)
    }

    /// The series case of the shared label helper must not drift from the action — they are the
    /// same copy decision, and the Home hero / detail row would otherwise disagree.
    @Test("ItemPlayButtonLabel agrees with the action's title", arguments: phases)
    func labelHelperAgrees(phase: Phase) {
        let series = makeSeries("ser")
        #expect(
            ItemPlayButtonLabel.title(for: .series(series), resumeEpisode: phase.resume)
                == SeriesPlayAction.resolve(resume: phase.resume, first: nil, episodesSettled: true).title
        )
    }
}
