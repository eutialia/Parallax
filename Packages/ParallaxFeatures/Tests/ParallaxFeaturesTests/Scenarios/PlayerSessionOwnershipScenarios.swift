import Foundation
import ParallaxCore
import ParallaxFeatures
import ParallaxFileBrowse
import ParallaxFileBrowseTestSupport
import ParallaxJellyfin
import ParallaxJellyfinTestSupport
import ParallaxPlayback
import Testing

@MainActor
@Suite("Player session ownership", .timeLimit(.minutes(1)))
struct PlayerSessionOwnershipScenarios {
    enum Route: String, CaseIterable, CustomTestStringConvertible {
        case smbOverBridge, jellyfin
        var testDescription: String { rawValue }

        var scheme: String { self == .jellyfin ? "https" : "http" }
    }

    @Test("closing a player frees the session it owned", arguments: Route.allCases)
    func closingFreesThePlayer(route: Route) async throws {
        let world: AppWorld
        switch route {
        case .jellyfin:
            let den = FakeJellyfinServer(name: "Den").user("ana").library("Films").movie("Heat", in: "Films", minutes: 170)
            world = try await AppWorld.launch(signedIn: [(den, "ana")])
            world.app.playback.play(ItemID(rawValue: den.itemID(of: "Heat")), in: try await world.session(on: den))
        case .smbOverBridge:
            world = try await AppWorld.launch(savedSMB: [(AppWorld.smbServer, "hunter2")])
            try await world.playSMBFilm()
        }

        weak var player: PlayerViewModel?
        player = try await world.openPlayer()
        try await world.streamIsReady(duration: .seconds(7200))
        try await world.streamPlays(at: .seconds(30), of: .seconds(7200))

        #expect(world.engine.loadedAssets.last?.url.scheme == route.scheme)

        await world.closePlayer()

        try await world.until { () async in player == nil }
    }
}
