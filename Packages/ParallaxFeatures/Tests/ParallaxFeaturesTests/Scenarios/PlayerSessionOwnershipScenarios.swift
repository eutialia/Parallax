import Foundation
import ParallaxCore
import ParallaxCoreTestSupport
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
    private static let nas = SMBServerData(host: "nas.local", username: "ana", domain: "WORKGROUP", shares: ["Media"])
    private static let ref = makeSMBRef(nas)

    enum Route: String, CaseIterable, CustomTestStringConvertible {
        case avkitOverBridge, vlcOverBridge, jellyfin
        var testDescription: String { rawValue }

        var scheme: String { self == .jellyfin ? "https" : "http" }

        var fileName: String { self == .vlcOverBridge ? "Film.mkv" : "Film.mp4" }

        var contents: Data {
            switch self {
            case .vlcOverBridge: Data([0x1A, 0x45, 0xDF, 0xA3] + Array(repeating: 0, count: 60))
            case .avkitOverBridge, .jellyfin:
                ISOBMFFFixtures.mp4(traks: [
                    ISOBMFFFixtures.trak(stsdEntries: ["avc1"], handler: "vide"),
                    ISOBMFFFixtures.trak(stsdEntries: ["mp4a"], handler: "soun"),
                ])
            }
        }
    }

    @Test("closing a player frees the session it owned", arguments: Route.allCases)
    func closingFreesThePlayer(route: Route) async throws {
        let world: AppWorld
        switch route {
        case .jellyfin:
            let den = FakeJellyfinServer(name: "Den").user("ana").library("Films").movie("Heat", in: "Films", minutes: 170)
            world = try await AppWorld.launch(signedIn: [(den, "ana")])
            world.app.playback.play(ItemID(rawValue: den.itemID(of: "Heat")), in: try await world.session(on: den))
        case .avkitOverBridge, .vlcOverBridge:
            world = try await AppWorld.launch(savedSMB: [(Self.nas, "hunter2")])
            world.nas.setFolder([SMBDirectoryEntry(name: route.fileName, isDirectory: false, size: 1, modifiedAt: nil)], share: "Media")
            world.nas.setContents(route.contents)
            let films = await world.openSMBFolder(Self.ref, share: "Media")
            try await world.until { !films.isLoading }
            films.play(try #require(films.media.first))
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
