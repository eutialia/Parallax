import Testing
import Foundation
import ParallaxCore
import ParallaxJellyfin
@testable import Parallax

/// One grid shape and whether it counts as stalled.
struct StalledCase: Sendable, CustomTestStringConvertible {
    let name: String
    /// Items the (successful) load returns. Ignored when `fails` is set.
    let items: [String]
    let fails: Bool
    /// Whether the grid is loaded at all before `isStalled` is read.
    let loads: Bool
    let isStalled: Bool
    var testDescription: String { name }
}

private let stalledCases: [StalledCase] = [
    StalledCase(name: "idle, pre-load", items: [], fails: false, loads: false, isStalled: false),
    StalledCase(name: "a successful (empty) load", items: [], fails: false, loads: true, isStalled: false),
    StalledCase(name: "a successful load with items", items: ["a"], fails: false, loads: true, isStalled: false),
    StalledCase(name: "a failed load with no items", items: [], fails: true, loads: true, isStalled: true),
]

/// `isStalled` is what `.recoversFromOffline` gates on, so its boundaries matter: only a blocking
/// full-screen failure (`.failed` AND no items) counts — never a loaded grid, and never the
/// stale-content refresh banner (which keeps its own manual "Try again").
@MainActor
@Suite("LibraryGridViewModel.isStalled")
struct LibraryGridViewModelStalledTests {
    /// Every fixture in this suite is one server; the grid ignores other sources' changes.

    private func makeVM(items: Result<Page<Item>, Error>) -> LibraryGridViewModel {
        let fake = FakeMediaRepository()
        fake.itemsResult = items
        return LibraryGridViewModel(repo: fake, source: testJellyfinSource, scope: .favorites, userDataActions: UserDataActions())
    }

    @Test("only a blocking full-screen failure is stalled", arguments: stalledCases)
    func isStalled(_ shape: StalledCase) async {
        let result: Result<Page<Item>, Error> = shape.fails
            ? .failure(AppError.network(URLError(.notConnectedToInternet)))
            : .success(makePage(shape.items.map { makeMovieItem($0) }))
        let vm = makeVM(items: result)

        if shape.loads { await vm.load() }

        #expect(vm.isStalled == shape.isStalled)
    }

    /// The boundary the suite's own doc names but nothing covered: a REFRESH that fails while the
    /// grid still holds content. That's the stale-content banner's case — the content stays on
    /// screen with its own manual "Try again", so treating it as stalled would make
    /// `.recoversFromOffline` silently refetch behind the user's back and defeat the banner.
    @Test("a failed refresh over existing content is NOT stalled — that's the stale-content banner")
    func failedRefreshWithItemsIsNotStalled() async throws {
        let fake = FakeMediaRepository()
        fake.itemsResult = .success(makePage([makeMovieItem("kept")]))
        let vm = LibraryGridViewModel(repo: fake, source: testJellyfinSource, scope: .favorites, userDataActions: UserDataActions())
        await vm.load()
        try #require(vm.items.isEmpty == false)

        fake.itemsResult = .failure(AppError.network(URLError(.notConnectedToInternet)))
        await vm.load()

        #expect(vm.items.map(\.id.rawValue) == ["kept"])
        #expect(vm.isStalled == false)
    }
}
