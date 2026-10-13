import Foundation
import ParallaxCore
import ParallaxFeatures
import ParallaxFileBrowse
import ParallaxJellyfin
import Testing

@MainActor
@Suite("SMB resume", .timeLimit(.minutes(1)))
struct SMBResumeScenarios {
    private static let nas = SMBServerData(host: "nas.local", username: "ana", domain: "WORKGROUP", shares: ["Media"])
    private static let ref = SMBServerRef(id: ServerID(rawValue: "smb-nas.local"), data: nas)
    private static let length = Duration.seconds(6_000)

    /// An MP4 whose `moov` box is not there yet, the way a file still being copied onto the NAS looks.
    private static let incompleteMP4 = Data(
        [0, 0, 0, 20] + Array("ftyp".utf8) + Array("isom".utf8) + [0, 0, 2, 0] + Array("isom".utf8)
            + [0, 0, 0, 16] + Array("mdat".utf8) + [0, 0, 0, 0, 0, 0, 0, 0]
    )
    /// A Matroska header: the probe takes the file as complete.
    private static let completeMKV = Data([0x1A, 0x45, 0xDF, 0xA3] + Array(repeating: 0, count: 60))

    private func watch(_ file: String, in world: AppWorld, until position: Duration) async throws {
        let folder = await world.openSMBFolder(Self.ref, share: "Media", path: "Movies")
        try await world.until { !folder.isLoading }
        folder.play(try #require(folder.media.first { $0.displayTitle == file }))
        try await world.openPlayer()
        try await world.streamIsReady(duration: Self.length)
        try await world.streamPlays(at: position, of: Self.length)
        await world.closePlayer()
    }

    @Test("a film still being copied to the NAS, closed near the end of the length shown, resumes where it was closed")
    func incompleteFileKeepsItsResumePoint() async throws {
        let world = try await AppWorld.launch(savedSMB: [(Self.nas, "hunter2")])
        world.nas.setFolder([SMBDirectoryEntry(name: "Heat.mp4", isDirectory: false, size: 36, modifiedAt: nil)], share: "Media", path: "Movies")
        world.nas.setContents(Self.incompleteMP4)
        try await watch("Heat", in: world, until: .seconds(5_900))

        await world.relaunch()
        let folder = await world.openSMBFolder(Self.ref, share: "Media", path: "Movies")
        try await world.until { !folder.isLoading }
        folder.play(try #require(folder.media.first))
        try await world.openPlayer()

        #expect(world.engine.loadedAssets.last?.startTime == .seconds(5_900))
    }

    @Test("a complete film watched to its end starts over from the top next time")
    func completeFileRestartsAfterTheEnd() async throws {
        let world = try await AppWorld.launch(savedSMB: [(Self.nas, "hunter2")])
        world.nas.setFolder([SMBDirectoryEntry(name: "Heat.mkv", isDirectory: false, size: 64, modifiedAt: nil)], share: "Media", path: "Movies")
        world.nas.setContents(Self.completeMKV)
        try await watch("Heat", in: world, until: .seconds(5_900))

        await world.relaunch()
        let folder = await world.openSMBFolder(Self.ref, share: "Media", path: "Movies")
        try await world.until { !folder.isLoading }
        folder.play(try #require(folder.media.first))
        try await world.openPlayer()

        #expect(world.engine.loadedAssets.last?.startTime == nil)
    }
}
