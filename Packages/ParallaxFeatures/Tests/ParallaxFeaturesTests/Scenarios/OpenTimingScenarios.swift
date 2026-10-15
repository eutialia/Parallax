import Foundation
import ParallaxCore
import ParallaxFeatures
import ParallaxFileBrowse
import ParallaxJellyfin
import ParallaxJellyfinTestSupport
import Testing
import ParallaxTestScaling

@MainActor
@Suite("Open timing", .scaledTimeLimit())
struct OpenTimingScenarios {
    @Test("an SMB film's open is recorded once, when its first frame plays, with no title or host in it")
    func smbOpenIsLoggedAtFirstPlaying() async throws {
        let world = try await AppWorld.launch(savedSMB: [(smbNAS, "hunter2")])
        let folder = await world.smbFilmFolder()
        folder.play(try #require(folder.media.first))

        let seen = await world.nas.operationGate.arrivalCount
        await world.nas.operationGate.close()
        let opening = Task { try await world.openPlayer() }
        await world.nas.operationGate.awaitArrivals(seen + 1)
        world.clock.advance(by: .milliseconds(611))
        await world.nas.operationGate.open()
        let player = try await opening.value
        world.clock.advance(by: .milliseconds(400))
        try await world.streamPlays(at: .seconds(1), of: .seconds(600))
        world.clock.advance(by: .seconds(5))
        try await world.streamPlays(at: .seconds(6), of: .seconds(600))

        let record = try #require(player.lastOpen)
        #expect(record.total == .milliseconds(1011))
        #expect(record.resolve == .milliseconds(611))
        #expect(record.load == .milliseconds(400))
        #expect(record.route == .smb(bridged: true))
        #expect(record.engine == .vlcKit)
        #expect(record.origin == .tap)
        #expect(record.logLine == "open → playing in 1011ms (resolve 611ms, load 400ms) source=smb transport=bridge engine=vlc origin=tap")
    }

    @Test("a Jellyfin film's open is recorded once, when its first frame plays, with its delivery method")
    func jellyfinOpenIsLoggedAtFirstPlaying() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films").movie("Heat", in: "Films")
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        world.app.playback.play(ItemID(rawValue: den.itemID(of: "Heat")), in: try await world.session(on: den))

        let player = try await world.openPlayer()
        world.clock.advance(by: .milliseconds(1234))
        try await world.streamPlays(at: .seconds(1), of: .seconds(600))
        world.clock.advance(by: .seconds(5))
        try await world.streamPlays(at: .seconds(6), of: .seconds(600))

        #expect(player.lastOpen?.logLine == "open → playing in 1234ms (resolve 0ms, load 1234ms) source=jellyfin transport=directPlay engine=avkit origin=tap")
    }

    @Test("an open that AVKit can't decode and VLC takes over is one record, on VLC, timed from the start")
    func rerouteIsOneRecordOnTheEngineThatPlayed() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films").movie("Heat", in: "Films")
        let world = try await AppWorld.launch(signedIn: [(den, "ana")])
        world.app.playback.play(ItemID(rawValue: den.itemID(of: "Heat")), in: try await world.session(on: den))
        let player = try await world.openPlayer()
        world.clock.advance(by: .milliseconds(700))

        world.streamFailsToDecode()
        try await world.until { world.engines.count == 2 && world.engine.calls.contains("play") }
        world.clock.advance(by: .milliseconds(300))
        try await world.streamPlays(at: .seconds(1), of: .seconds(600))

        let record = try #require(player.lastOpen)
        #expect(record.engine == .vlcKit)
        #expect(record.total == .milliseconds(1000))
        #expect(record.load == .milliseconds(300))
    }

    @Test("a failed open leaves no record, and the retry's record is timed from the retry")
    func retryRecordsFromTheRetry() async throws {
        let world = try await AppWorld.launch(savedSMB: [(smbNAS, "hunter2")])
        let folder = await world.smbFilmFolder()
        folder.play(try #require(folder.media.first))
        let player = try await world.openPlayer()
        world.clock.advance(by: .seconds(30))
        world.streamFailsToDecode()
        try await world.until { player.hasFailed }
        #expect(player.lastOpen == nil)

        await player.retry()
        try await world.until { world.engines.count == 2 && world.engine.calls.contains("play") }
        world.clock.advance(by: .milliseconds(250))
        try await world.streamPlays(at: .seconds(1), of: .seconds(600))

        let record = try #require(player.lastOpen)
        #expect(record.origin == .retry)
        #expect(record.total == .milliseconds(250))
    }

    @Test("an open that fails and is never retried leaves no record")
    func failedOpenLeavesNoRecord() async throws {
        let world = try await AppWorld.launch(savedSMB: [(smbNAS, "hunter2")])
        let folder = await world.smbFilmFolder()
        folder.play(try #require(folder.media.first))
        let player = try await world.openPlayer()

        world.streamFailsToDecode()
        try await world.until { player.hasFailed }
        try await world.streamPlays(at: .seconds(1), of: .seconds(600))

        #expect(player.lastOpen == nil)
    }

}

private extension AppWorld {
    func smbFilmFolder() async -> SMBBrowseViewModel {
        nas.setFolder([SMBDirectoryEntry(name: "Heat.mkv", isDirectory: false, size: 1, modifiedAt: nil)], share: "Media")
        nas.setContents(Data([0x1A, 0x45, 0xDF, 0xA3] + Array(repeating: 0, count: 60)))
        let folder = await openSMBFolder(makeSMBRef(smbNAS), share: "Media")
        try? await until { !folder.isLoading }
        return folder
    }
}

private extension PlayerViewModel {
    var hasFailed: Bool {
        if case .failed = phase { true } else { false }
    }
}

private let smbNAS = SMBServerData(host: "nas.local", username: "ana", domain: "WORKGROUP", shares: ["Media"])
