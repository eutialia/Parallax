import ParallaxCore
import ParallaxFeatures
import ParallaxJellyfinTestSupport
import Testing

@MainActor
@Suite("Favorites", .timeLimit(.minutes(1)))
struct FavoritesScenarios {
    @Test("favorites from two servers show as one section per server, each in its server's order")
    func sectionPerServer() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
            .movie("Heat", in: "Films", year: 1995).movie("Arrival", in: "Films", year: 2016).movie("Ronin", in: "Films")
            .favorite("Heat").favorite("Arrival")
        let attic = FakeJellyfinServer(name: "Attic").user("bo").library("Movies")
            .movie("Alien", in: "Movies").favorite("Alien")
        let world = try await AppWorld.launch(signedIn: [(den, "ana"), (attic, "bo")])
        let favorites = FavoritesViewModel()

        await favorites.load(from: world.app)

        #expect(favorites.visibleSections.map(\.title) == ["Den", "Attic"])
        #expect(favorites.visibleSections.map { $0.grid.items.map(\.displayTitle) } == [["Arrival", "Heat"], ["Alien"]])
    }

    @Test("unfavoriting from a tile's menu removes it from Favorites and clears the heart on its page")
    func unfavoriteFromTheMenu() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
            .movie("Heat", in: "Films", year: 1995).movie("Arrival", in: "Films", year: 2016)
            .favorite("Heat").favorite("Arrival")
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        let session = try await world.session(on: den)
        let favorites = FavoritesViewModel()
        await favorites.load(from: world.app)
        let heat = try #require(favorites.visibleSections.first?.grid.items.first { $0.displayTitle == "Heat" })
        let detail = await world.app.movieDetail(heat.id, on: session)
        await detail.load()
        #expect(detail.isFavorite)

        let unfavorite = try #require(MediaTileMenuAction.menu(for: heat, on: session).first {
            if case .toggleFavorite = $0 { true } else { false }
        })
        await world.app.perform(unfavorite, on: session)

        try await world.until { favorites.visibleSections.first?.grid.items.map(\.displayTitle) == ["Arrival"] }
        try await world.until { !detail.isFavorite }
        #expect(!den.isFavorite("Heat"))
        let reopened = FavoritesViewModel()
        await reopened.load(from: world.app)
        #expect(reopened.visibleSections.first?.grid.items.map(\.displayTitle) == ["Arrival"])
    }
}
