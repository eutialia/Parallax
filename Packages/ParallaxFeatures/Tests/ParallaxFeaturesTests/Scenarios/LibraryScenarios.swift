import ParallaxCore
import ParallaxFeatures
import ParallaxJellyfinTestSupport
import Testing

@MainActor
@Suite("Library", .timeLimit(.minutes(1)))
struct LibraryScenarios {
    @Test("the library list shows each server's libraries under its name, and a hidden library drops out")
    func listShowsEachServersLibraries() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films").library("Shows", of: .shows)
        let attic = FakeJellyfinServer(name: "Attic").user("bo").library("Movies")
        let world = try await AppWorld.launch(signedIn: [(den, "ana"), (attic, "bo")])
        try await world.openHome()
        #expect(world.sidebar == [
            AppWorld.SidebarSection(title: "Den", libraries: ["Films", "Shows"]),
            AppWorld.SidebarSection(title: "Attic", libraries: ["Movies"]),
        ])

        let visibleLibraries = VisibleLibrariesModel(session: try await world.session(on: den), app: world.app)
        await visibleLibraries.load()
        let shows = try #require(visibleLibraries.collections.first { $0.name == "Shows" })
        await visibleLibraries.toggle(shows)

        try await world.until {
            world.sidebar == [
                AppWorld.SidebarSection(title: "Den", libraries: ["Films"]),
                AppWorld.SidebarSection(title: "Attic", libraries: ["Movies"]),
            ]
        }
    }

    @Test("a large library pages in fifty at a time until it runs out")
    func gridPagesThroughALargeLibrary() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
        for number in 1 ... 120 {
            den.movie("Movie \(number)", in: "Films", year: 1900 + number)
        }
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        let grid = try await world.openLibrary("Films", on: den)

        await grid.load()
        #expect(grid.items.count == 50)
        #expect(grid.items.first?.displayTitle == "Movie 120")

        await grid.loadMore()
        #expect(grid.items.count == 100)
        await grid.loadMore()
        #expect(grid.items.count == 120)
        await grid.loadMore()
        #expect(grid.items.count == 120)
        #expect(grid.items.last?.displayTitle == "Movie 1")
    }

    @Test("sorting by title reorders the grid, and a genre narrows it to that genre")
    func sortAndGenreChangeTheGrid() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
            .movie("Heat", in: "Films", year: 1995, genres: ["Crime", "Drama"])
            .movie("Arrival", in: "Films", year: 2016, genres: ["Drama"])
            .movie("Ronin", in: "Films", year: 1998, genres: ["Action"])
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        let grid = try await world.openLibrary("Films", on: den)
        await grid.load()
        #expect(grid.items.map(\.displayTitle) == ["Arrival", "Ronin", "Heat"])
        try await world.until { grid.availableGenres == ["Action", "Crime", "Drama"] }

        grid.sortField = .title
        try await world.until { grid.items.map(\.displayTitle) == ["Arrival", "Heat", "Ronin"] }

        grid.selectedGenre = "Drama"
        try await world.until { grid.items.map(\.displayTitle) == ["Arrival", "Heat"] }
    }
}
