import Foundation
import ParallaxJellyfin
import ParallaxCore

/// `nonisolated`: pure copy derivation over value types, with nothing main-actor about it. The
/// app target defaults to `@MainActor`, which would otherwise make `SeriesPlayAction.resolve`
/// (nonisolated by design — it's a plain value the tests exercise off the main actor) unable to
/// call `shouldResumeSeries`.
nonisolated enum ItemPlayButtonLabel {
    /// Which copy a surface's play pill can ever show, and therefore how wide it reserves.
    /// One reserve for both would size every movie pill for season/episode numbers it can
    /// never render — two characters of dead width on every movie detail.
    enum ReserveKind {
        /// Titles are only ever "Play" / "Resume" — movie detail.
        case verbOnly
        /// Titles can carry season and episode numbers — series detail, and the Home hero
        /// (its play target is often an episode, so it produces "Resume S# E#" too).
        case episodeNumbered
    }

    /// Widest play CTA copy for a surface — sizes the play pill so Play ↔ Resume can't reflow
    /// the row. Synthetic, not a title anything renders: it's the upper bound on the shape, so
    /// double-digit seasons and episodes ("Resume S12 E34") fit inside the reserve instead of
    /// growing the pill and sliding the Favorite disc — the exact reflow the reserve prevents.
    static func layoutReserveTitle(for kind: ReserveKind) -> String {
        switch kind {
        case .verbOnly: "Resume"
        case .episodeNumbered: "Resume S99 E99"
        }
    }

    /// Detail-page play CTA copy from the resume/next-up episode.
    /// Home hero labels live on `HomeHeroFeedEntry.playButtonTitle` instead.
    static func title(for item: Item, resumeEpisode: Episode?) -> String {
        switch item {
        case .series:
            // One copy decision for series, owned by `SeriesPlayAction` — the detail row builds
            // the same value to get its play TARGET, and two spellings would drift. The settled
            // flag only picks between the two TARGET-LESS availabilities; the title is the same
            // either way, so this caller (which wants only the copy) doesn't have to know it.
            return SeriesPlayAction.resolve(resume: resumeEpisode, first: nil, episodesSettled: true).title
        case .movie, .episode:
            return item.userData.isInProgress ? "Resume" : "Play"
        }
    }

    /// Resume when the next-up episode has progress, or it isn't the very first episode
    /// (earlier ones are watched — you're continuing the series). Otherwise a fresh "Play".
    /// Internal: the series detail's action row uses the same test to decide whether the
    /// next-up target presents as Resume (with a separate from-the-beginning Play) or IS
    /// the plain Play.
    static func shouldResumeSeries(_ episode: Episode) -> Bool {
        if episode.userData.isInProgress { return true }
        let isFirstEpisode = (episode.parentIndexNumber ?? 1) == 1 && (episode.indexNumber ?? 1) == 1
        return !isFirstEpisode
    }
}

/// The series hero's play CTA, resolved to a VALUE before the row builds it: a title that always
/// exists, and an availability that says whether there's anything to play — and if not, whether
/// that's temporary.
///
/// Structural on purpose. `PrimaryPlayButton` carries the hero action row's default-focus pin
/// (see `HeroForeground`), tvOS resolves default focus exactly once — at the skeleton→content
/// cut — and `SeriesDetailViewModel.load()` reaches `.loaded` a round-trip BEFORE the episode
/// lists and the /Shows/NextUp target. So the row's first laid-out frame has no play target,
/// and the old `if resume … else if first …` (no else) emitted no pill at all on that frame:
/// the pin had nothing to pin and Favorite took the landing for the screen's whole life
/// Making the title unconditional keeps the pill — and the pin — in the tree from
/// frame one; `availability` gates only the ACTION. Not `.disabled()`, which would drop the pill
/// out of the tvOS focus chain and reproduce the bug exactly — which is also why `.unavailable`
/// dims the pill instead of disabling it.
nonisolated struct SeriesPlayAction: Equatable, Sendable {
    /// What the pill's ACTION resolves to. Three states, not an optional target: "no episodes
    /// yet" and "no episodes at all" look identical in the target alone, and collapsing them
    /// left an empty or failed-to-load series with a permanently enabled, tappable no-op pill
    /// promising VoiceOver it was "loading episodes" forever.
    enum Availability: Equatable, Sendable {
        /// The episode fetch hasn't finished. The action no-ops; the pill looks normal.
        case loading
        /// The fetch finished and produced nothing — an empty series, or a failed load. The
        /// action still no-ops, and the pill says so (dimmed, with a hint).
        case unavailable
        case ready(ItemID)
    }

    /// Never empty — "Play", "Resume", or "Resume S# E#". Present in every state: the pill has
    /// to render on every frame (see below), so it always needs copy.
    let title: String
    let availability: Availability

    /// The episode to start, or nil when there is nothing to start — yet, or at all.
    var target: ItemID? { if case .ready(let id) = availability { id } else { nil } }
    var isReady: Bool { target != nil }

    /// The only honest signal that the pill is currently inert — it stays enabled and focusable
    /// in both target-less states, so nothing else tells VoiceOver. Empty when ready: an
    /// always-present hint would announce on every activation.
    var accessibilityHint: String {
        switch availability {
        case .loading: "Loading episodes"
        case .unavailable: "No episodes available"
        case .ready: ""
        }
    }

    /// The hero row's former two branches, verbatim: a next-up episode that reads as a resume
    /// (`ItemPlayButtonLabel.shouldResumeSeries`) is the Resume target; everything else is a
    /// plain "Play" aimed at the next-up episode when there is one, else the first episode.
    /// With no target at all, `episodesSettled` (`SeriesDetailViewModel.episodesSettled` — true
    /// once `load()` has returned, success or not) decides which target-less state it is.
    static func resolve(resume: Episode?, first: Episode?, episodesSettled: Bool) -> SeriesPlayAction {
        if let resume, ItemPlayButtonLabel.shouldResumeSeries(resume) {
            return SeriesPlayAction(title: resumeTitle(resume), availability: .ready(resume.id))
        }
        guard let target = (resume ?? first)?.id else {
            return SeriesPlayAction(title: "Play", availability: episodesSettled ? .unavailable : .loading)
        }
        return SeriesPlayAction(title: "Play", availability: .ready(target))
    }

    private static func resumeTitle(_ episode: Episode) -> String {
        if let season = episode.parentIndexNumber, let index = episode.indexNumber {
            return "Resume S\(season) E\(index)"
        }
        return "Resume"
    }
}
