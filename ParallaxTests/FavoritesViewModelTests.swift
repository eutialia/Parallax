import Testing
import Foundation
import ParallaxCore
import ParallaxJellyfin
@testable import Parallax

/// The Favorites wall's coordinator. Its whole job is to hold N per-server grids to ONE sort choice
/// while never comparing their items against each other — so these tests pin both halves: the sort
/// reaches every server, and each section stays exactly the order its server returned.
@MainActor
@Suite("FavoritesViewModel")
struct FavoritesViewModelTests {
    private func session(_ id: String, name: String? = nil) -> Session {
        Session(
            id: ServerID(rawValue: id),
            data: JellyfinServerData(
                serverURL: URL(string: "https://\(id).example.test")!,
                serverName: name ?? "Server \(id)",
                user: UserSnapshot(id: "u-\(id)", name: "alice", serverLastUpdatedAt: nil)
            ),
            accessToken: "tok-\(id)"
        )
    }

    private func movie(_ id: String) -> Item {
        .movie(Movie(
            id: ItemID(rawValue: id), title: id, overview: nil, year: nil, runtime: nil,
            communityRating: nil, officialRating: nil, genres: [],
            primaryTag: nil, backdropTags: [], logoTag: nil, thumbTag: nil,
            userData: UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: true)
        ))
    }

    private func page(_ ids: [String]) -> Page<Item> {
        Page(items: ids.map(movie), total: ids.count, nextCursor: nil)
    }

    /// Builds a coordinator over the given per-server fakes, keyed by server id.
    private func load(
        _ repos: [(id: String, repo: FakeMediaRepository)],
        into existing: FavoritesViewModel? = nil
    ) async -> FavoritesViewModel {
        // Built here, not as a default argument: `FavoritesViewModel.init` is MainActor-isolated
        // and default arguments are evaluated in a nonisolated context.
        let vm = existing ?? FavoritesViewModel()
        let table = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0.repo) })
        await vm.load(
            sessions: repos.map { session($0.id) },
            repoFactory: { @Sendable session in table[session.id.rawValue]! },
            userDataActions: UserDataActions()
        )
        return vm
    }

    private func repo(items: [String], genres: [String] = []) -> FakeMediaRepository {
        let fake = FakeMediaRepository()
        fake.itemsResult = .success(page(items))
        fake.genresResult = .success(genres)
        return fake
    }

    private func failingRepo() -> FakeMediaRepository {
        let fake = FakeMediaRepository()
        fake.itemsResult = .failure(AppError.network(URLError(.notConnectedToInternet)))
        return fake
    }

    // MARK: - Sectioning

    @Test("One section per server, in the order the servers were given")
    func oneSectionPerServerInOrder() async {
        let vm = await load([
            (id: "a", repo: repo(items: ["a1"])),
            (id: "b", repo: repo(items: ["b1"])),
        ])
        #expect(vm.sections.map(\.id) == [ServerID(rawValue: "a"), ServerID(rawValue: "b")])
        #expect(vm.sections.map(\.title) == ["Server a", "Server b"])
    }

    /// The core guarantee of sectioning over merging: a section's items are EXACTLY what its server
    /// returned, in that order. Nothing is reordered against another server's items, so each
    /// section's sort is server-authoritative and no client-side comparator is ever needed.
    @Test("Each section preserves its own server's ordering verbatim")
    func sectionsPreserveServerOrder() async {
        let vm = await load([
            (id: "a", repo: repo(items: ["zebra", "apple"])),
            (id: "b", repo: repo(items: ["mango"])),
        ])
        #expect(vm.sections[0].grid.items.map(\.id.rawValue) == ["zebra", "apple"])
        #expect(vm.sections[1].grid.items.map(\.id.rawValue) == ["mango"])
    }

    @Test("A server with no favorites contributes no section — a bare header over nothing reads as breakage")
    func emptySectionsAreHidden() async {
        let vm = await load([
            (id: "a", repo: repo(items: ["a1"])),
            (id: "b", repo: repo(items: [])),
        ])
        #expect(vm.sections.count == 2)
        #expect(vm.visibleSections.map(\.id) == [ServerID(rawValue: "a")])
    }

    // MARK: - Sort fan-out

    /// Without this the sort control would be decorative on every server but the first.
    @Test("Choosing a sort pushes it to every section")
    func sortFansOutToEverySection() async {
        let vm = await load([
            (id: "a", repo: repo(items: ["a1"])),
            (id: "b", repo: repo(items: ["b1"])),
        ])

        vm.sortField = .title

        let expected = ItemSort(field: .title, direction: .ascending)
        #expect(vm.sections.allSatisfy { $0.grid.sort == expected })
    }

    /// A field switch adopts that field's natural direction rather than inheriting the previous
    /// one — otherwise picking "Title" after "Newest" would silently mean "Z to A".
    @Test("A field switch resets to that field's natural direction, everywhere")
    func fieldSwitchAdoptsNaturalDirection() async {
        let vm = await load([(id: "a", repo: repo(items: ["a1"]))])

        vm.sortField = .title                 // ascending is natural
        vm.sortDirection = .descending        // user then flips it
        vm.sortField = .dateAdded             // natural: descending

        #expect(vm.sort == ItemSort(field: .dateAdded, direction: .descending))
        #expect(vm.sections[0].grid.sort == vm.sort)
    }

    @Test("A genre choice fans out as a filter to every section")
    func genreFansOut() async {
        let vm = await load([
            (id: "a", repo: repo(items: ["a1"], genres: ["Action"])),
            (id: "b", repo: repo(items: ["b1"], genres: ["Action"])),
        ])

        vm.selectedGenre = "Action"

        #expect(vm.sections.allSatisfy { $0.grid.filter.genres == ["Action"] })
    }

    /// A server signed into AFTER a sort was chosen must open on that sort, not the default —
    /// otherwise adding a server silently gives you one section ordered differently from the rest.
    @Test("A section built after a sort was chosen inherits it")
    func newSectionsInheritTheCurrentSort() async {
        let vm = FavoritesViewModel()
        vm.sortField = .communityRating
        vm.selectedGenre = "Drama"

        _ = await load([(id: "a", repo: repo(items: ["a1"]))], into: vm)

        #expect(vm.sections[0].grid.sort == ItemSort(field: .communityRating, direction: .descending))
        #expect(vm.sections[0].grid.filter.genres == ["Drama"])
    }

    // MARK: - Genres

    /// A genre present on only one server still has to be selectable, or its titles are unreachable
    /// from this screen.
    @Test("Genres are the union across servers, deduplicated and sorted")
    func genresUnionAcrossServers() async {
        let vm = await load([
            (id: "a", repo: repo(items: ["a1"], genres: ["Sci-Fi", "Action"])),
            (id: "b", repo: repo(items: ["b1"], genres: ["Action", "Drama"])),
        ])
        #expect(vm.availableGenres == ["Action", "Drama", "Sci-Fi"])
    }

    // MARK: - Failure isolation

    /// One unreachable server must not blank a working one — the difference between "a server is
    /// down" and "Favorites is broken".
    @Test("One failed server keeps the others' sections and doesn't fail the screen")
    func partialFailureKeepsWorkingSections() async {
        let vm = await load([
            (id: "a", repo: repo(items: ["a1"])),
            (id: "b", repo: failingRepo()),
        ])

        #expect(vm.hasFailedEntirely == false)
        #expect(vm.sections[0].grid.items.map(\.id.rawValue) == ["a1"])
        #expect(vm.failedSections.map(\.id) == [ServerID(rawValue: "b")])
    }

    /// A failed section stays VISIBLE (unlike an empty one) so the user learns which server is
    /// unreachable, instead of quietly seeing fewer favorites than they have.
    @Test("A failed section is still shown, so the missing server is named")
    func failedSectionsStayVisible() async {
        let vm = await load([
            (id: "a", repo: repo(items: ["a1"])),
            (id: "b", repo: failingRepo()),
        ])
        #expect(vm.visibleSections.map(\.id) == [ServerID(rawValue: "a"), ServerID(rawValue: "b")])
    }

    @Test("Only an all-server failure turns the whole screen into an error")
    func totalFailureFailsTheScreen() async {
        let vm = await load([
            (id: "a", repo: failingRepo()),
            (id: "b", repo: failingRepo()),
        ])
        #expect(vm.hasFailedEntirely)
        #expect(vm.isEmpty == false)
    }

    // MARK: - Empty state

    @Test("Every server settling with nothing is the real empty state")
    func allEmptyIsEmptyState() async {
        let vm = await load([
            (id: "a", repo: repo(items: [])),
            (id: "b", repo: repo(items: [])),
        ])
        #expect(vm.isEmpty)
        #expect(vm.hasFailedEntirely == false)
        #expect(vm.visibleSections.isEmpty)
    }

    /// A failed server has nothing to show but is NOT "no favorites" — that message would be a lie
    /// about content the user may well have.
    @Test("A failure is never reported as an empty Favorites list")
    func failureIsNotEmptiness() async {
        let vm = await load([(id: "a", repo: failingRepo())])
        #expect(vm.isEmpty == false)
    }
}
