import Foundation
import JellyfinAPI
import ParallaxCore
import ParallaxJellyfin
import Testing
@testable import Parallax

/// The hostile timing behind the focus bug, pinned so it can't drift silently.
///
/// `SeriesDetailViewModel.load()` publishes `.loaded` as soon as the detail + season list are
/// in, then fetches the episode lists and the /Shows/NextUp target. So there is a real window —
/// one that a slow server widens to seconds — where the series detail is fully laid out with
/// `firstEpisode == nil && resumeEpisode == nil`. tvOS resolves default focus exactly once, at
/// the skeleton→content cut inside that window, which is why the hero's play pill has to exist
/// structurally rather than appear later (`SeriesPlayAction`).
///
/// This suite asserts that ordering ON PURPOSE. If `load()` is ever reordered to hold `.loaded`
/// until the episodes land, this test fails — and that's the point: the reorder invalidates the
/// premise `SeriesPlayActionTests`' "episodes still in flight" case is defending, so it should
/// force a look rather than quietly leaving that case guarding nothing.
@Suite("SeriesDetailViewModel.load() publishes .loaded before the episodes")
@MainActor
struct SeriesDetailViewModelLoadOrderTests {

    @Test("at the first .loaded frame the hero has no play target yet")
    func loadedLandsBeforeEpisodes() async {
        let client = GatedSeriesLibraryClient()
        let repo = LibraryRepository(session: makeSession("test-server"), client: client)
        let vm = SeriesDetailViewModel(
            repo: repo,
            itemID: ItemID(rawValue: "ser1"),
            source: testJellyfinSource,
            userDataActions: UserDataActions()
        )

        let load = Task { await vm.load() }
        // `getEpisodes` is only reached after `load()` has published `.loaded`, so its entry IS
        // the frame under test — an exact edge to wait on, with no sleeping or timeout.
        await client.entered.waitOpened()

        guard case .loaded = vm.state else {
            Issue.record("getEpisodes ran before .loaded — the ordering this suite pins has changed")
            return
        }

        // The frame tvOS pins default focus on.
        #expect(vm.firstEpisode == nil)
        #expect(vm.resumeEpisode == nil)
        // Target-less AND unsettled: the pill reads `.loading`, not `.unavailable` — the state
        // that dims it. `episodesSettled` is what separates this frame from an empty series.
        #expect(vm.episodesSettled == false)
        #expect(SeriesPlayAction.resolve(resume: vm.resumeEpisode,
                                         first: vm.firstEpisode,
                                         episodesSettled: vm.episodesSettled).availability == .loading)

        await client.episodeGate.open()
        await load.value

        // The teeth: the fake WAS holding both, so the nils above are the ordering, not an
        // empty fixture.
        #expect(vm.firstEpisode?.id == ItemID(rawValue: "e1"))
        #expect(vm.resumeEpisode?.id == ItemID(rawValue: "nu"))
        #expect(vm.episodesSettled)
        #expect(SeriesPlayAction.resolve(resume: vm.resumeEpisode,
                                         first: vm.firstEpisode,
                                         episodesSettled: vm.episodesSettled).isReady)
    }
}

/// One-shot gate: every `waitOpened()` suspends until the first `open()`, then all of them (and
/// any later one) pass straight through.
private actor OneShotGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitOpened() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

/// A `JellyfinLibraryClient` that answers a one-series library instantly EXCEPT for
/// `getEpisodes`, which announces itself on `entered` and then parks on `episodeGate` — the seam
/// that holds `load()` inside its `.loaded`-but-episode-less window for as long as the test needs.
///
/// Deliberately a real `LibraryRepository` over a fake transport, not a fake repository:
/// `SeriesDetailViewModel` takes the concrete actor, and the DTO→domain translation is part of
/// the ordering under test.
private final class GatedSeriesLibraryClient: JellyfinLibraryClient, Sendable {
    /// Opens the instant `getEpisodes` is entered, i.e. the first moment after `.loaded`.
    let entered = OneShotGate()
    let episodeGate = OneShotGate()

    private static func dto(_ id: String, _ name: String, _ type: BaseItemKind) -> BaseItemDto {
        var dto = BaseItemDto()
        dto.id = id
        dto.name = name
        dto.type = type
        return dto
    }

    private static func episodeDto(_ id: String, season: Int, index: Int) -> BaseItemDto {
        var dto = self.dto(id, "Episode \(index)", .episode)
        dto.seriesID = "ser1"
        dto.seasonID = "se1"
        dto.parentIndexNumber = season
        dto.indexNumber = index
        return dto
    }

    func getCollections() async throws -> [BaseItemDto] { [] }

    func getItems(scope: LibraryScope, filter: ParallaxCore.ItemFilter, sort: ItemSort, startIndex: Int, limit: Int) async throws -> (items: [BaseItemDto], total: Int) {
        ([], 0)
    }

    func getItemDetail(itemID: String) async throws -> BaseItemDto {
        Self.dto("ser1", "A Series", .series)
    }

    func getItemsByIDs(_ ids: [String]) async throws -> [BaseItemDto] { [] }

    func getSeasons(seriesID: String) async throws -> [BaseItemDto] {
        var season = Self.dto("se1", "Season 1", .season)
        season.seriesID = "ser1"
        season.indexNumber = 1
        return [season]
    }

    func getEpisodes(seasonID: String) async throws -> [BaseItemDto] {
        await entered.open()
        await episodeGate.waitOpened()
        return [Self.episodeDto("e1", season: 1, index: 1)]
    }

    func getContinueWatching() async throws -> [BaseItemDto] { [] }
    func getNextUp() async throws -> [BaseItemDto] { [] }
    func getRecentlyAdded(limit: Int, includeItemTypes: [BaseItemKind]) async throws -> [BaseItemDto] { [] }
    func search(query: String, scope: SearchScope) async throws -> [BaseItemDto] { [] }

    func setFavorite(itemID: String, isFavorite: Bool) async throws -> UserItemData {
        UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: isFavorite)
    }

    func setPlayed(itemID: String, isPlayed: Bool) async throws -> UserItemData {
        UserItemData(played: isPlayed, playbackPositionTicks: 0, playCount: isPlayed ? 1 : 0, isFavorite: false)
    }

    func seriesNextUp(seriesID: String) async throws -> BaseItemDto? {
        Self.episodeDto("nu", season: 2, index: 3)
    }

    func mediaSegments(itemID: String) async throws -> [MediaSegmentDto] { [] }
    func adjacentEpisodes(seriesID: String, episodeID: String) async throws -> [BaseItemDto] { [] }
    func genres(scope: LibraryScope) async throws -> [String] { [] }
}
