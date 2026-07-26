import Testing
import Foundation
import ParallaxCore
import ParallaxJellyfin
@testable import Parallax

/// Who is allowed to start a fetch, and what a caller of `load()` is owed.
///
/// A grid can be *seeded* with a sort/filter (the Favorites wall opens N grids on an already-chosen
/// sort) or *told* one later (`setSort`/`setFilter`). Only the second refetches. That split used to
/// be a `didSet` the initializer was assumed to skip — untrue under `@Observable`, which rewrites
/// `sort`/`filter` into computed properties, so `init` ran the setter and armed a reload nobody
/// asked for. It then raced the caller's own `load()`, which bailed on `guard state != .loading`
/// and took `loadGenres()` with it: a grid stuck on the spinner with a permanently empty genre
/// picker, roughly half the time.
@MainActor
@Suite("LibraryGridViewModel fetch arming")
struct LibraryGridViewModelSortSeedTests {
    private let seeded = ItemSort(field: .title, direction: .ascending)

    private func makeGrid(
        _ repo: any MediaRepository,
        sort: ItemSort,
        filter: ItemFilter = ItemFilter(genres: ["Drama"])
    ) -> LibraryGridViewModel {
        LibraryGridViewModel(
            repo: repo,
            source: testJellyfinSource,
            scope: .favorites,
            userDataActions: UserDataActions(),
            sort: sort,
            filter: filter
        )
    }

    private func makeRepo() -> FakeMediaRepository {
        let fake = FakeMediaRepository()
        fake.itemsResult = .success(makePage([makeMovieItem("a1")]))
        fake.genresResult = .success(["Action"])
        return fake
    }

    /// The deterministic statement of the bug: construction alone must reach no server. A wall-clock
    /// wait (not a yield loop) so an armed reload has every chance to run — the assertion is an
    /// invariant, so waiting longer can never make it pass spuriously.
    @Test("Seeding sort/filter through init arms no fetch — the grid stays idle until load()")
    func seedingArmsNoFetch() async {
        let fake = makeRepo()
        let vm = makeGrid(fake, sort: seeded)

        try? await Task.sleep(for: .milliseconds(200))

        #expect(vm.state == .idle)
        #expect(vm.items.isEmpty)
        #expect(fake.lastSort == nil)
        #expect(fake.lastFilter == nil)
    }

    /// The user-visible half: one `load()` on a seeded grid settles it, on the seeded sort, WITH its
    /// genres. Reading `availableGenres` right after the await is the regression — a second armed
    /// fetch made `load()` bail before `loadGenres()`.
    @Test("A seeded grid settles on its seeded sort, genres included, in one load()")
    func seededGridLoadsOnceWithGenres() async {
        let fake = makeRepo()
        let vm = makeGrid(fake, sort: seeded)

        await vm.load()

        #expect(vm.state == .loaded)
        #expect(vm.items.map(\.id.rawValue) == ["a1"])
        #expect(vm.availableGenres == ["Action"])
        #expect(fake.lastSort == seeded)
        #expect(fake.lastFilter?.genres == ["Drama"])
    }

    /// The interleaving that remains legal in production — the toolbar's sort landing while the
    /// view's first `load()` is still in flight. Whichever fetch wins, the grid must settle on the
    /// NEW sort and still have asked for genres: `load()` joins the in-flight fetch instead of
    /// returning as a no-op.
    @Test("A sort change racing the first load() still settles, on the new sort, with genres")
    func sortChangeRacingFirstLoadStillSettles() async {
        let fake = makeRepo()
        let vm = makeGrid(fake, sort: seeded)
        let chosen = ItemSort(field: .communityRating, direction: .descending)

        vm.setSort(chosen)     // arms reload()
        await vm.load()        // may lose or win the race

        // Two fetches are in play, so settling is what needs waiting on — not the assertions below.
        await waitUntil { vm.state == .loaded }
        #expect(vm.state == .loaded)
        #expect(vm.sort == chosen)
        #expect(fake.lastSort == chosen)
        #expect(vm.availableGenres == ["Action"])
    }

    /// The same interleaving, but PINNED rather than raced: the sort's refetch is parked mid-flight,
    /// so `load()` provably arrives while the grid sits at `.loading`. It must join that fetch and
    /// still request genres — the old `guard state != .loading else { return }` returned a grid the
    /// caller thought was settled and left the genre picker empty for the rest of the session.
    @Test("load() arriving during an in-flight refetch joins it, and still fetches genres")
    func loadJoinsAnInFlightRefetch() async {
        let gated = GatedMediaRepository(page: makePage([makeMovieItem("a1")]), genres: ["Action"])
        let vm = makeGrid(gated, sort: seeded)
        let chosen = ItemSort(field: .communityRating, direction: .descending)

        vm.setSort(chosen)
        await waitUntil { gated.didStartItems }        // the refetch is parked inside the gate
        #expect(vm.state == .loading)

        let joined = Task { @MainActor in await vm.load() }
        await waitUntil { vm.isLoadingGenres }         // the join armed the genre fetch
        gated.release()
        await joined.value

        #expect(vm.state == .loaded)
        #expect(vm.items.map(\.id.rawValue) == ["a1"])
        #expect(vm.availableGenres == ["Action"])
        #expect(gated.lastSort == chosen)
    }

    /// `setSort`/`setFilter` are the only fetch triggers, and they no-op on an unchanged value — a
    /// coordinator re-pushing the same choice must not refetch every section.
    @Test("Re-pushing the current sort or filter refetches nothing")
    func idempotentPush() async {
        let fake = makeRepo()
        let vm = makeGrid(fake, sort: seeded)
        await vm.load()
        let generationAfterLoad = vm.refreshGeneration

        vm.setSort(seeded)
        vm.setFilter(ItemFilter(genres: ["Drama"]))
        try? await Task.sleep(for: .milliseconds(100))

        #expect(vm.refreshGeneration == generationAfterLoad)
        #expect(vm.state == .loaded)
    }
}

/// A repository whose `items` fetch parks until `release()`, so a test can hold a grid at `.loading`
/// and control exactly what a concurrent caller observes. Local to this suite because it's the only
/// one that needs to pin the interleaving; `FakeMediaRepository` stays canned and instant.
private final class GatedMediaRepository: MediaRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var recordedSort: ItemSort?
    private let page: Page<Item>
    private let genreList: [String]

    init(page: Page<Item>, genres: [String]) {
        self.page = page
        self.genreList = genres
    }

    /// True once a fetch has entered the gate — i.e. the grid really is mid-flight.
    var didStartItems: Bool { lock.withLock { started } }
    var lastSort: ItemSort? { lock.withLock { recordedSort } }

    func collections() async throws -> [MediaCollection] { [] }
    func genres(in scope: LibraryScope) async throws -> [String] { genreList }

    func items(in scope: LibraryScope, filter: ItemFilter, sort: ItemSort, cursor: PageCursor?) async throws -> Page<Item> {
        let passThrough: Bool = lock.withLock {
            started = true
            recordedSort = sort
            return released
        }
        if !passThrough {
            await withCheckedContinuation { continuation in
                let resumeNow: Bool = lock.withLock {
                    guard !released else { return true }
                    waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return page
    }

    func release() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            released = true
            defer { waiters = [] }
            return waiters
        }
        for continuation in pending { continuation.resume() }
    }
}
