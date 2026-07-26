import Testing
import Foundation
import ParallaxCore
import ParallaxJellyfin
@testable import Parallax

/// `isStalled` is what `.recoversFromOffline` gates on, so its boundaries matter: only a blocking
/// full-screen failure (`.failed` AND no items) counts — never a loaded grid, and never the
/// stale-content refresh banner (which keeps its own manual "Try again").
@MainActor
@Suite("LibraryGridViewModel.isStalled")
struct LibraryGridViewModelStalledTests {
    /// Every fixture in this suite is one server; the grid ignores other sources' changes.
    private let previewSource = MediaSourceID.jellyfin(ServerID(rawValue: "test-server"))

    private func makeVM(items: Result<Page<Item>, Error>) -> LibraryGridViewModel {
        let fake = FakeMediaRepository()
        fake.itemsResult = items
        return LibraryGridViewModel(repo: fake, source: previewSource, scope: .favorites, userDataActions: UserDataActions())
    }

    @Test("idle (pre-load) is not stalled")
    func idleNotStalled() {
        #expect(makeVM(items: .success(Page(items: [], total: 0, nextCursor: nil))).isStalled == false)
    }

    @Test("a successful load is not stalled")
    func loadedNotStalled() async {
        let vm = makeVM(items: .success(Page(items: [], total: 0, nextCursor: nil)))
        await vm.load()
        #expect(vm.isStalled == false)
    }

    @Test("a failed load with no items is stalled")
    func failedEmptyStalled() async {
        let vm = makeVM(items: .failure(AppError.network(URLError(.notConnectedToInternet))))
        await vm.load()
        #expect(vm.isStalled)
    }
}
