import Foundation
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxCore

@Suite("ReachabilityState")
struct ReachabilityStateTests {
    /// The monitor dedupes its stream to TRANSITIONS, so equality is load-bearing: if either
    /// facet dropped out of it, a Low Data Mode toggle (or an offline→online edge) would be
    /// swallowed instead of published.
    @Test("both facets participate in identity, so neither transition can be deduped away")
    func bothFacetsAreTransitions() {
        let online = ReachabilityState(isSatisfied: true, isConstrained: false)
        #expect(online != ReachabilityState(isSatisfied: false, isConstrained: false))
        #expect(online != ReachabilityState(isSatisfied: true, isConstrained: true))
        #expect(online == ReachabilityState(isSatisfied: true, isConstrained: false))
    }
}

@Suite("MediaRepository defaults")
struct MediaRepositoryDefaultsTests {
    /// HTTP-backed repositories are stateless, so the protocol gives them a no-op `teardown()`
    /// and only connection-holding conformers override it.
    private struct StatelessRepository: MediaRepository {
        func collections() async throws -> [MediaCollection] { [LibraryFixtures.collection()] }

        func items(
            in scope: LibraryScope, filter: ItemFilter, sort: ItemSort, cursor: PageCursor?
        ) async throws -> Page<Item> {
            Page(items: [.movie(LibraryFixtures.movie())], total: 1, nextCursor: nil)
        }

        func genres(in scope: LibraryScope) async throws -> [String] { ["Drama"] }
    }

    @Test("a conformer that never overrides teardown still satisfies the protocol")
    func teardownDefaultsToNoOp() async throws {
        let repository: any MediaRepository = StatelessRepository()
        await repository.teardown()

        // Still usable afterwards — the default teardown released nothing.
        let collections = try await repository.collections()
        #expect(collections.count == 1)
    }

    @Test("the browse surface answers through the existential")
    func browseSurfaceIsReachableThroughTheExistential() async throws {
        let repository: any MediaRepository = StatelessRepository()
        let page = try await repository.items(
            in: .favorites, filter: ItemFilter(), sort: .defaultForLibrary, cursor: nil
        )
        #expect(page.total == 1)
        let genres = try await repository.genres(in: .favorites)
        #expect(genres == ["Drama"])
    }
}
