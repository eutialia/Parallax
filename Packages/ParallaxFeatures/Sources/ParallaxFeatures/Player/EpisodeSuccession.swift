import Foundation
import Observation
import ParallaxCore
import ParallaxJellyfin

/// The playing item's intro/outro segments and its previous/next episodes, fetched best-effort
/// beside the stream, and the latch that keeps two episode swaps from overlapping.
@Observable
@MainActor
final class EpisodeSuccession {
    /// Intro/outro markers for the playing item — empty when the server has no
    /// segment provider, which is the normal "no skip UI" case, never an error.
    private(set) var segments: [MediaSegment] = []
    /// Previous/next episode in airing order (`.none` for movies and at the
    /// series' first/last episode). Source for the prev/next buttons + autoplay.
    private(set) var adjacentEpisodes: AdjacentEpisodes = .none
    @ObservationIgnored private var segmentsTask: Task<Void, Never>?
    /// Serializes episode swaps so a double-press — or an auto-advance racing a
    /// manual Next — can't kick off two overlapping reloads.
    private(set) var isAdvancing = false
    /// Whether the playing item is episodic (part of a series), so the prev/next
    /// transport is meaningful. False for movies — the centre cluster then shows
    /// play/pause alone. Set once per item from its type and stable across an
    /// episode→episode swap (both episodic), so the always-mounted prev/next buttons
    /// never unmount mid-press on tvOS.
    private(set) var supportsEpisodeNavigation = false
    /// Flips true when a natural end-of-video has nowhere to advance (a movie or a
    /// series finale). `AppModel.runPlayer` closes the player on it — same exit path as
    /// the Close/▼ chevron — instead of stranding a paused glyph on the final frame.
    private(set) var playbackDidComplete = false

    /// Best-effort fetch of intro/outro segments for an item (empty on error or
    /// when the server has no provider). Defaulted to empty so tests/previews need
    /// no wiring.
    @ObservationIgnored private let fetchSegments: @Sendable (ItemID) async -> [MediaSegment]
    /// Best-effort fetch of an episode's previous/next neighbors — args are
    /// (seriesID, episodeID), `.none` on error or for non-episodes. Defaulted.
    @ObservationIgnored private let fetchAdjacent: @Sendable (ItemID, ItemID) async -> AdjacentEpisodes

    init(
        fetchSegments: @escaping @Sendable (ItemID) async -> [MediaSegment],
        fetchAdjacent: @escaping @Sendable (ItemID, ItemID) async -> AdjacentEpisodes
    ) {
        self.fetchSegments = fetchSegments
        self.fetchAdjacent = fetchAdjacent
    }

    isolated deinit {
        segmentsTask?.cancel()
    }

    /// The actionable segment (intro/recap/outro) holding `seconds`, or nil.
    func activeSegment(atSeconds seconds: Double) -> MediaSegment? {
        guard !segments.isEmpty, seconds.isFinite else { return nil }
        return segments.first { $0.kind.playerAction != nil && $0.contains(seconds: seconds) }
    }

    /// Best-effort fetch of intro/outro segments + the prev/next episode for the
    /// item that just started. Never blocks or fails playback; errors resolve to
    /// no segments / no neighbors. Runs concurrently with the playback resolve.
    func load(for item: ItemDetail) {
        segments = []
        adjacentEpisodes = .none
        playbackDidComplete = false
        segmentsTask?.cancel()
        let itemID = item.id
        let episode: (series: ItemID, id: ItemID)?
        switch item {
        case .episode(let detail): episode = (detail.episode.seriesID, detail.episode.id)
        case .movie, .series, .season: episode = nil
        }
        // Stable for the whole session (only flips on the initial movie-vs-episode load,
        // never during an episode→episode swap), so the centre cluster can drop prev/next
        // for movies without ever unmounting a focused button on tvOS.
        supportsEpisodeNavigation = episode != nil
        segmentsTask = Task { [weak self, fetchSegments, fetchAdjacent] in
            async let segmentsResult = fetchSegments(itemID)
            var neighbors = AdjacentEpisodes.none
            if let episode {
                neighbors = await fetchAdjacent(episode.series, episode.id)
            }
            let resolvedSegments = await segmentsResult
            guard !Task.isCancelled else { return }
            self?.segments = resolvedSegments
            self?.adjacentEpisodes = neighbors
        }
    }

    /// Runs one episode swap, unless another is already running.
    func advance(_ swap: () async -> Void) async {
        guard !isAdvancing else { return }
        isAdvancing = true
        defer { isAdvancing = false }
        await swap()
    }

    /// The video ended with nowhere to advance.
    func complete() {
        playbackDidComplete = true
    }

    /// The session is over: its segments and neighbors go, and any fetch still bringing them.
    func reset() {
        segmentsTask?.cancel()
        segmentsTask = nil
        segments = []
        adjacentEpisodes = .none
    }
}

#if DEBUG
extension EpisodeSuccession {
    /// Awaits the detached segments + neighbors fetch, so a test can read them without racing it.
    func awaitLoad() async {
        await segmentsTask?.value
    }
}
#endif
