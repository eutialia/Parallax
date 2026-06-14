import Testing
import ParallaxCore
@testable import Parallax

@MainActor
@Suite("LibraryListViewModel")
struct LibraryListViewModelTests {
    @Test("load() publishes collections from any MediaRepository")
    func loadsCollections() async {
        let fake = FakeMediaRepository()
        fake.collectionsResult = .success([
            MediaCollection(id: CollectionID(rawValue: "c1"), name: "Movies", collectionType: .movies, primaryTag: nil)
        ])
        let vm = JellyfinLibraryListViewModel(repo: fake)
        await vm.load()
        #expect(vm.collections.count == 1)
        #expect(vm.collections.first?.name == "Movies")
    }
}
