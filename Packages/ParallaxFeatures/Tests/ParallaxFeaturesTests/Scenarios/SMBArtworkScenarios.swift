import Foundation
import ParallaxCore
import ParallaxFeatures
import ParallaxFileBrowse
import ParallaxJellyfin
import Testing

@MainActor
@Suite("SMB artwork", .timeLimit(.minutes(1)))
struct SMBArtworkScenarios {
    @Test("thumbnail generation waits while the player is on screen and finishes once it closes")
    func generationPausesUnderThePlayer() async throws {
        let nas = SMBServerData(host: "nas.local", username: "ana", domain: "WORKGROUP", shares: ["Media"])
        let ref = SMBServerRef(id: ServerID(rawValue: "smb-nas.local"), data: nas)
        let world = try await AppWorld.launch(savedSMB: [(nas, "hunter2")])
        world.nas.setFolder([
            SMBDirectoryEntry(name: "Heat.mkv", isDirectory: false, size: 4096, modifiedAt: nil),
            SMBDirectoryEntry(name: "Ran.mkv", isDirectory: false, size: 4096, modifiedAt: nil),
        ], share: "Media")
        world.nas.setContents(Data(repeating: 0, count: 4096))
        let provider = world.app.services.mediaArtworkProvider
        let root = await world.openSMBFolder(ref, share: "Media")
        try await world.until { root.media.count == 2 }
        let (heat, ran) = (root.media[0], root.media[1])

        root.play(ran)
        try await world.until { await provider.isPausedForPlayback }
        let tile = Task { await provider.artwork(for: heat, ref: ref, sidecar: nil) }
        try await world.until { await provider.generationsPausedForPlayback == 1 }
        #expect(world.thumbnailer.requests == [])

        world.app.playback.dismiss()
        await world.clock.waitForSleepers()
        world.clock.advance(by: .seconds(1))
        let artwork = await tile.value

        #expect(artwork.duration == .seconds(42))
        #expect(world.thumbnailer.requests.map(\.lastPathComponent) == ["Heat.mkv"])
        #expect(await provider.isPausedForPlayback == false)
    }
}
