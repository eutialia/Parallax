import Foundation
import ParallaxJellyfin

enum ItemPlayButtonLabel {
    /// Widest hero CTA copy — sizes the play pill so Play / Resume S# E# don't reflow.
    static let layoutReserveTitle = "Resume S9 E9"

    /// Primary hero CTA copy. The hero only surfaces series with a playable next-up
    /// episode (see `HomeViewModel.load()`), so a series reads "Play" for a fresh start
    /// (first episode, no progress) or "Resume S# E#" once it's underway. No "View" —
    /// the hero always plays something.
    static func title(for item: Item, resumeEpisode: Episode?) -> String {
        switch item {
        case .series:
            guard let ep = resumeEpisode else { return "Play" }
            return shouldResumeSeries(ep) ? resumeEpisodeTitle(ep) : "Play"
        case .movie, .episode:
            return hasResumeProgress(item) ? "Resume" : "Play"
        }
    }

    static func hasResumeProgress(_ item: Item) -> Bool {
        let ud = item.userData
        return ud.playbackPositionTicks > 0 && !ud.played
    }

    /// Resume when the next-up episode has progress, or it isn't the very first episode
    /// (earlier ones are watched — you're continuing the series). Otherwise a fresh "Play".
    private static func shouldResumeSeries(_ episode: Episode) -> Bool {
        if episode.userData.playbackPositionTicks > 0 && !episode.userData.played { return true }
        let isFirstEpisode = (episode.parentIndexNumber ?? 1) == 1 && (episode.indexNumber ?? 1) == 1
        return !isFirstEpisode
    }

    private static func resumeEpisodeTitle(_ episode: Episode) -> String {
        if let season = episode.parentIndexNumber, let index = episode.indexNumber {
            return "Resume S\(season) E\(index)"
        }
        return "Resume"
    }
}
