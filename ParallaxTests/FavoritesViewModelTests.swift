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
            sessions: repos.map { makeSession($0.id) },
            repoFactory: { @Sendable session in table[session.id.rawValue]! },
            userDataActions: UserDataActions()
        )
        return vm
    }

    /// A server whose favorites are exactly `items`, in that order — everything this wall
    /// reads is a favorite, so the fixture hard-codes it.
    private func repo(items: [String], genres: [String] = []) -> FakeMediaRepository {
        let fake = FakeMediaRepository()
        fake.itemsResult = .success(makePage(items.map { makeMovieItem($0, isFavorite: true) }))
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

    /// Without this the sort control would be decorative on every server but the first. Asserted on
    /// BOTH sides: the section's own state, and the sort each server's repository was last asked
    /// for — a coordinator that stored the choice locally and never refetched would satisfy the
    /// first half alone while every section kept showing the server's default order.
    @Test("Choosing a sort pushes it to every section, and to every server")
    func sortFansOutToEverySection() async {
        let repoA = repo(items: ["a1"])
        let repoB = repo(items: ["b1"])
        let vm = await load([(id: "a", repo: repoA), (id: "b", repo: repoB)])

        vm.sortField = .title
        await waitUntil { repoA.lastSort?.field == .title && repoB.lastSort?.field == .title }

        let expected = ItemSort(field: .title, direction: .ascending)
        #expect(vm.sections.allSatisfy { $0.grid.sort == expected })
        #expect(repoA.lastSort == expected)
        #expect(repoB.lastSort == expected)
    }

    /// A field switch adopts that field's natural direction rather than inheriting the previous
    /// one — otherwise picking "Title" after "Newest" would silently mean "Z to A". The expectation
    /// reads the field's OWN `naturalDirection` rather than restating the mapping, so retuning a
    /// field's default doesn't require editing this test to keep it honest.
    @Test("A field switch resets to that field's natural direction, everywhere")
    func fieldSwitchAdoptsNaturalDirection() async {
        let repoA = repo(items: ["a1"])
        let vm = await load([(id: "a", repo: repoA)])

        vm.sortField = .title                 // ascending is natural
        vm.sortDirection = .descending        // user then flips it
        vm.sortField = .dateAdded             // natural: descending

        let expected = ItemSort(field: .dateAdded, direction: ItemSort.Field.dateAdded.naturalDirection)
        await waitUntil { repoA.lastSort == expected }
        #expect(vm.sort == expected)
        #expect(vm.sections[0].grid.sort == expected)
        #expect(repoA.lastSort == expected)
    }

    @Test("A genre choice fans out as a filter to every section, and to every server")
    func genreFansOut() async {
        let repoA = repo(items: ["a1"], genres: ["Action"])
        let repoB = repo(items: ["b1"], genres: ["Action"])
        let vm = await load([(id: "a", repo: repoA), (id: "b", repo: repoB)])

        vm.selectedGenre = "Action"
        await waitUntil { repoA.lastFilter?.genres == ["Action"] && repoB.lastFilter?.genres == ["Action"] }

        #expect(vm.sections.allSatisfy { $0.grid.filter.genres == ["Action"] })
        #expect(repoA.lastFilter?.genres == ["Action"])
        #expect(repoB.lastFilter?.genres == ["Action"])
    }

    /// A server signed into AFTER a sort was chosen must open on that sort, not the default —
    /// otherwise adding a server silently gives you one section ordered differently from the rest.
    /// Its FIRST fetch has to carry the choice too: inheriting it only in local state would fetch
    /// the default order and then quietly display it under the wrong sort label.
    @Test("A section built after a sort was chosen inherits it, first fetch included")
    func newSectionsInheritTheCurrentSort() async {
        let vm = FavoritesViewModel()
        vm.sortField = .communityRating
        vm.selectedGenre = "Drama"

        let late = repo(items: ["a1"])
        _ = await load([(id: "a", repo: late)], into: vm)

        let expected = ItemSort(field: .communityRating, direction: ItemSort.Field.communityRating.naturalDirection)
        #expect(vm.sections[0].grid.sort == expected)
        #expect(vm.sections[0].grid.filter.genres == ["Drama"])
        // No barrier: a seeded grid arms no fetch of its own, so the ONE fetch each section makes is
        // the awaited `load()` — by the time `FavoritesViewModel.load()` returns, its server has
        // been asked, on this sort. (It used to need `await waitUntil { late.lastSort != nil }`,
        // because seeding also armed a racing reload.)
        #expect(late.lastSort == expected)
        #expect(late.lastFilter?.genres == ["Drama"])
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

    // MARK: - Failure / empty state matrix

    /// The whole screen-state matrix in one table. The five separate tests this replaced each read
    /// ONE property off a VM in one of these shapes, so no single one could catch a regression that
    /// got a different property wrong for the same input — the "a failure is not emptiness" and
    /// "a failed section stays visible" pairs are exactly that mistake, stated twice.
    ///
    /// `sections` here means "which server ids each derived list should contain", so a shape's whole
    /// observable surface is spelled out at once.
    @Test("screen state per failure shape", arguments: favoritesShapes)
    func screenStateFollowsTheFailureShape(_ shape: FavoritesShape) async {
        let vm = await load(shape.servers.map { server in
            (id: server.id, repo: server.fails ? failingRepo() : repo(items: server.items))
        })

        #expect(vm.hasFailedEntirely == shape.hasFailedEntirely)
        #expect(vm.isEmpty == shape.isEmpty)
        #expect(vm.visibleSections.map(\.id.rawValue) == shape.visible)
        #expect(vm.failedSections.map(\.id.rawValue) == shape.failed)
        // The working server keeps its items regardless of what its neighbours did — the difference
        // between "a server is down" and "Favorites is broken".
        for server in shape.servers where !server.fails {
            let section = vm.sections.first { $0.id.rawValue == server.id }
            #expect(section?.grid.items.map(\.id.rawValue) == server.items)
        }
    }
}

/// One configuration of the Favorites wall plus every screen-level answer it must give.
struct FavoritesShape: Sendable, CustomTestStringConvertible {
    struct Server: Sendable {
        let id: String
        let items: [String]
        var fails: Bool = false
    }

    let name: String
    let servers: [Server]
    let hasFailedEntirely: Bool
    let isEmpty: Bool
    /// Server ids expected in `visibleSections`, in order.
    let visible: [String]
    /// Server ids expected in `failedSections`, in order.
    let failed: [String]

    var testDescription: String { name }
}

private let favoritesShapes: [FavoritesShape] = [
    // A failed section stays VISIBLE (unlike an empty one) so the user learns which server is
    // unreachable, instead of quietly seeing fewer favorites than they have.
    FavoritesShape(
        name: "one server down, one healthy",
        servers: [.init(id: "a", items: ["a1"]), .init(id: "b", items: [], fails: true)],
        hasFailedEntirely: false,
        isEmpty: false,
        visible: ["a", "b"],
        failed: ["b"]
    ),
    // Only an all-server failure turns the whole screen into an error — and a failed server has
    // nothing to show but is NOT "no favorites", which would be a lie about content the user has.
    FavoritesShape(
        name: "every server down",
        servers: [.init(id: "a", items: [], fails: true), .init(id: "b", items: [], fails: true)],
        hasFailedEntirely: true,
        isEmpty: false,
        visible: ["a", "b"],
        failed: ["a", "b"]
    ),
    FavoritesShape(
        name: "the only server is down",
        servers: [.init(id: "a", items: [], fails: true)],
        hasFailedEntirely: true,
        isEmpty: false,
        visible: ["a"],
        failed: ["a"]
    ),
    // Every server settling with nothing is the one true empty state.
    FavoritesShape(
        name: "every server settles empty",
        servers: [.init(id: "a", items: []), .init(id: "b", items: [])],
        hasFailedEntirely: false,
        isEmpty: true,
        visible: [],
        failed: []
    ),
    FavoritesShape(
        name: "every server has favorites",
        servers: [.init(id: "a", items: ["a1"]), .init(id: "b", items: ["b1"])],
        hasFailedEntirely: false,
        isEmpty: false,
        visible: ["a", "b"],
        failed: []
    ),
]
