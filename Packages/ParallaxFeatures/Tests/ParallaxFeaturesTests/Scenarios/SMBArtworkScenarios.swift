import Foundation
import ParallaxCore
@testable import ParallaxFeatures
import ParallaxFileBrowse
import ParallaxFileBrowseTestSupport
import ParallaxJellyfin
import Testing
import ParallaxTestScaling

@MainActor
@Suite("SMB artwork", .scaledTimeLimit())
struct SMBArtworkScenarios {
    @Test("thumbnail generation waits while the player is on screen and finishes once it closes")
    func generationPausesUnderThePlayer() async throws {
        let world = try await AppWorld.launch(savedSMB: [(AppWorld.smbServer, "hunter2")])
        world.nas.setFolder([
            SMBDirectoryEntry(name: "Heat.mkv", isDirectory: false, size: 4096, modifiedAt: nil),
            SMBDirectoryEntry(name: "Ran.mkv", isDirectory: false, size: 4096, modifiedAt: nil),
        ], share: "Media")
        world.nas.setContents(Data(repeating: 0, count: 4096))
        let provider = world.app.services.mediaArtworkProvider
        let root = await world.openSMBFolder(AppWorld.smbRef, share: "Media")
        try await world.until { root.media.count == 2 }
        let (heat, ran) = (root.media[0], root.media[1])

        root.play(ran)
        try await world.until { await provider.isPausedForPlayback }
        let tile = Task { await provider.artwork(for: heat, ref: AppWorld.smbRef, sidecar: nil) }
        try await world.until { await provider.generationsPausedForPlayback == 1 }
        #expect(world.thumbnailer.requests == [])

        world.app.playback.dismiss()
        try await world.clock.waitForSleep(dueIn: .milliseconds(600))
        world.clock.advance(by: .milliseconds(600))
        let artwork = await tile.value

        #expect(artwork.duration == .seconds(42))
        #expect(world.thumbnailer.requests.map(\.lastPathComponent) == ["Heat.mkv"])
        #expect(await provider.isPausedForPlayback == false)
    }

    @Test("a poster that never finishes downloading is dropped at its ceiling, and the tile falls back to a frame grab")
    func hungSidecarFallsBackToAFrameGrab() async throws {
        let world = try await AppWorld.launch(savedSMB: [(AppWorld.smbServer, "hunter2")])
        world.nas.setFolder([
            SMBDirectoryEntry(name: "Heat.mkv", isDirectory: false, size: 4096, modifiedAt: nil),
            SMBDirectoryEntry(name: "Heat-poster.jpg", isDirectory: false, size: 512, modifiedAt: nil),
        ], share: "Media")
        world.nas.setContents(Data(repeating: 0, count: 4096))
        let root = await world.openSMBFolder(AppWorld.smbRef, share: "Media")
        try await world.until { root.media.count == 1 }
        let heat = root.media[0]
        let poster = try #require(root.artwork[heat.id])

        let listed = await world.nas.operationGate.arrivalCount
        await world.nas.operationGate.close()
        let loading = Task {
            await world.app.services.mediaArtworkProvider.artwork(for: heat, ref: AppWorld.smbRef, sidecar: poster)
        }
        await world.nas.operationGate.awaitArrivals(listed + 1)
        try await world.clock.waitForSleep(dueIn: .seconds(10))
        world.clock.advance(by: .seconds(10))
        try await world.until { await world.nas.operationGate.arrivalCount >= listed + 2 }
        await world.nas.operationGate.open()
        let artwork = await loading.value

        #expect(artwork.duration == .seconds(42))
        #expect(world.thumbnailer.requests.map(\.lastPathComponent) == ["Heat.mkv"])
    }

    @Test("a grey mosaic frame is not cached; the grab retries deeper in the file and caches that frame")
    func mosaicFrameRetriesDeeper() async throws {
        let (world, provider, heat, ref) = try await Self.openHeat()
        world.thumbnailer.script = [TestFrames.mosaic]

        let artwork = await provider.artwork(for: heat, ref: ref, sidecar: nil)
        let revisit = await provider.artwork(for: heat, ref: ref, sidecar: nil)

        #expect(Self.frame(of: artwork) == "scene")
        #expect(Self.frame(of: revisit) == "scene")
        #expect(world.thumbnailer.positions == [0.05, 0.15])
    }

    @Test("the frame grab is told which container the probe identified, on every position it tries",
          arguments: [
            (Data([0x00, 0x00, 0x01, 0xBA]) + Data(repeating: 0, count: 4092), Container.mpegps),
            (Data([0x1A, 0x45, 0xDF, 0xA3]) + Data(repeating: 0, count: 4092), .mkv),
            (Data(repeating: 0, count: 4096), nil),
          ] as [(Data, Container?)])
    func grabCarriesTheProbedContainer(contents: Data, expected: Container?) async throws {
        let (world, provider, heat, ref) = try await Self.openHeat(contents: contents)
        world.thumbnailer.script = [TestFrames.mosaic]

        _ = await provider.artwork(for: heat, ref: ref, sidecar: nil)

        #expect(world.thumbnailer.positions == [0.05, 0.15])
        #expect(world.thumbnailer.containers == [expected, expected])
    }

    @Test("a file that only decodes to grey shows no artwork and is not grabbed again within its backoff")
    func mosaicOnlyFileBacksOff() async throws {
        let (world, provider, heat, ref) = try await Self.openHeat()
        world.thumbnailer.script = [TestFrames.mosaic, TestFrames.mosaic, TestFrames.mosaic]

        let first = await provider.artwork(for: heat, ref: ref, sidecar: nil)
        let withinBackoff = await provider.artwork(for: heat, ref: ref, sidecar: nil)

        #expect(Self.frame(of: first) == "none")
        #expect(Self.frame(of: withinBackoff) == "none")
        #expect(world.thumbnailer.positions == [0.05, 0.15, 0.25])
    }

    @Test("a grey mosaic captured during playback is not cached, so the tile still gets a real frame")
    func mosaicBackfillIsDropped() async throws {
        let (world, provider, heat, ref) = try await Self.openHeat()

        await provider.backfillThumbnail(
            item: heat, ref: ref, duration: .seconds(42), captureFramePerformsIO: false
        ) { TestFrames.mosaic }
        let artwork = await provider.artwork(for: heat, ref: ref, sidecar: nil)

        #expect(Self.frame(of: artwork) == "scene")
        #expect(world.thumbnailer.positions == [0.05])
    }

    @Test("a file that decodes only to grey after a sidecar timeout leaves the host's window open for two concurrent generations")
    func greyFileAfterSidecarBlipDoesNotShrinkTheWindow() async throws {
        let ref = AppWorld.smbRef
        let world = try await AppWorld.launch(savedSMB: [(AppWorld.smbServer, "hunter2")])
        world.nas.setFolder([
            SMBDirectoryEntry(name: "Heat.mkv", isDirectory: false, size: 4096, modifiedAt: nil),
            SMBDirectoryEntry(name: "Heat-poster.jpg", isDirectory: false, size: 512, modifiedAt: nil),
            SMBDirectoryEntry(name: "Ran.wmv", isDirectory: false, size: 4096, modifiedAt: nil),
            SMBDirectoryEntry(name: "Alien.wmv", isDirectory: false, size: 4096, modifiedAt: nil),
        ], share: "Media")
        world.nas.setContents(Data(repeating: 0, count: 4096))
        let root = await world.openSMBFolder(ref, share: "Media")
        try await world.until { root.media.count == 3 }
        let provider = world.app.services.mediaArtworkProvider
        let heat = try #require(root.media.first { "\($0.id)".contains("Heat.mkv") })
        let others = root.media.filter { $0.id != heat.id }
        let poster = try #require(root.artwork[heat.id])
        world.thumbnailer.script = [TestFrames.mosaic, TestFrames.mosaic, TestFrames.mosaic]

        let listed = await world.nas.operationGate.arrivalCount
        await world.nas.operationGate.close()
        let grey = Task { await provider.artwork(for: heat, ref: ref, sidecar: poster) }
        await world.nas.operationGate.awaitArrivals(listed + 1)
        try await world.clock.waitForSleep(dueIn: .seconds(10))
        world.clock.advance(by: .seconds(10))
        try await world.until { await world.nas.operationGate.arrivalCount >= listed + 2 }
        await world.nas.operationGate.open()
        _ = await grey.value
        #expect(world.thumbnailer.positions == [0.05, 0.15, 0.25])

        let hold = AsyncGate(open: false)
        world.thumbnailer.hold = hold
        let tiles = others.map { item in Task { await provider.artwork(for: item, ref: ref, sidecar: nil) } }
        try await world.until { await hold.arrivalCount == 2 }
        await hold.open()
        for tile in tiles { _ = await tile.value }
    }

    @Test("a grey thumbnail cached by an older build is evicted and regenerated on first read; a good one is served as is")
    func cachedGreyThumbnailIsRegenerated() async throws {
        let (world, provider, heat, ref) = try await Self.openHeat()
        let ran = try await Self.addFile("Ran.wmv", to: world, ref: ref)
        let seeding = SMBThumbnailCache(directory: world.thumbnailCacheDirectory)
        _ = await seeding.store(TestFrames.mosaic, duration: .seconds(42), for: try Self.key(of: heat, ref: ref))
        _ = await seeding.store(TestFrames.scene, duration: .seconds(42), for: try Self.key(of: ran, ref: ref))

        let good = await provider.artwork(for: ran, ref: ref, sidecar: nil)
        #expect(Self.frame(of: good) == "scene")
        #expect(world.thumbnailer.positions == [])

        let regenerated = await provider.artwork(for: heat, ref: ref, sidecar: nil)
        #expect(Self.frame(of: regenerated) == "scene")
        #expect(world.thumbnailer.positions == [0.05])
    }

    @Test("a grey poster cached by the sidecar tier is served across a relaunch without a re-download")
    func greyPosterSurvivesRelaunch() async throws {
        let ref = AppWorld.smbRef
        let world = try await AppWorld.launch(savedSMB: [(AppWorld.smbServer, "hunter2")])
        world.nas.setFolder([
            SMBDirectoryEntry(name: "Heat.mkv", isDirectory: false, size: 4096, modifiedAt: nil),
            SMBDirectoryEntry(name: "Heat-poster.jpg", isDirectory: false, size: 4096, modifiedAt: nil),
        ], share: "Media")
        world.nas.setContents(TestFrames.mosaic)
        let root = await world.openSMBFolder(ref, share: "Media")
        try await world.until { root.media.count == 1 }
        let heat = root.media[0]
        let poster = try #require(root.artwork[heat.id])
        _ = await world.app.services.mediaArtworkProvider.artwork(for: heat, ref: ref, sidecar: poster)
        #expect(world.thumbnailer.positions == [])

        let relaunched = SMBThumbnailCache(directory: world.thumbnailCacheDirectory)
        #expect(await relaunched.existing(for: try Self.key(of: heat, ref: ref)) != nil)
    }

    @Test("a seeded grey poster is served on first read without a frame grab")
    func seededGreyPosterIsServed() async throws {
        let (world, provider, heat, ref) = try await Self.openHeat()
        let seeding = SMBThumbnailCache(directory: world.thumbnailCacheDirectory)
        _ = await seeding.store(TestFrames.mosaic, duration: nil, for: try Self.key(of: heat, ref: ref), origin: .artwork)

        let artwork = await provider.artwork(for: heat, ref: ref, sidecar: nil)

        #expect(Self.frame(of: artwork) == "mosaic")
        #expect(world.thumbnailer.positions == [])
    }

    @Test("leaving a folder withdraws its queued thumbnails; only the folder on screen is fetched")
    func leavingAFolderWithdrawsItsThumbnails() async throws {
        let (world, hold) = try await Self.launchOverWAN()
        let provider = world.app.services.mediaArtworkProvider
        let (root, rootScreen) = world.showSMBLevel("")
        try await world.until { root.media.map(\.displayTitle) == ["Alpha", "Omega"] }
        let alpha = Task { await provider.artwork(for: root.media[0], ref: AppWorld.smbRef, sidecar: nil) }
        await hold.awaitArrivals(1)

        world.leave(root, rootScreen)
        alpha.cancel()
        let (films, filmsScreen) = world.showSMBLevel("Films")
        try await world.until { films.media.count == 8 }
        let firstFilm = Task { await provider.artwork(for: films.media[0], ref: AppWorld.smbRef, sidecar: nil) }
        films.prefetchWindow(from: 0, lookahead: 7)
        try await world.until { () async in await provider.queuedGenerations() == (visible: 1, prefetch: 7) }

        world.leave(films, filmsScreen)
        firstFilm.cancel()
        await filmsScreen.value
        let (_, rootAgain) = world.showSMBLevel(root)
        let alphaAgain = Task { await provider.artwork(for: root.media[0], ref: AppWorld.smbRef, sidecar: nil) }
        root.prefetchWindow(from: 0, lookahead: 1)
        await hold.open()
        try await world.until { () async in world.requestedFiles.contains("Omega.wmv") }
        _ = await alphaAgain.value
        rootAgain.cancel()

        #expect(world.requestedFiles.sorted() == ["Alpha.wmv", "Alpha.wmv", "Omega.wmv"])
    }

    @Test("a thumbnail scrolled past in the folder on screen still finishes while the backlog has room; files the viewport never neared are not fetched")
    func scrollingPastKeepsTheFolderWork() async throws {
        let (world, hold) = try await Self.launchOverWAN()
        let provider = world.app.services.mediaArtworkProvider
        let (films, filmsScreen) = world.showSMBLevel("Films")
        try await world.until { films.media.count == 8 }

        films.prefetchWindow(from: 0, lookahead: 3)
        await hold.awaitArrivals(1)
        let firstFilm = Task { await provider.artwork(for: films.media[0], ref: AppWorld.smbRef, sidecar: nil) }
        films.prefetchWindow(from: 5, lookahead: 3)
        let sixthFilm = Task { await provider.artwork(for: films.media[5], ref: AppWorld.smbRef, sidecar: nil) }
        firstFilm.cancel()
        sixthFilm.cancel()
        await hold.open()
        try await world.until { () async in world.requestedFiles.count == 7 }
        filmsScreen.cancel()

        #expect(world.requestedFiles.sorted() == [
            "Film 1.wmv", "Film 2.wmv", "Film 3.wmv", "Film 4.wmv", "Film 6.wmv", "Film 7.wmv", "Film 8.wmv",
        ])
    }

    @Test("a folder that appears again while its last appearance winds down hands its lookahead over again")
    func reappearingFolderHandsItsLookaheadAgain() async throws {
        let (world, hold) = try await Self.launchOverWAN()
        let (films, firstScreen) = world.showSMBLevel("Films")
        try await world.until { films.media.count == 8 }
        films.prefetchWindow(from: 0, lookahead: 3)
        await hold.awaitArrivals(1)

        world.leave(films, firstScreen)
        let (_, secondScreen) = world.showSMBLevel(films)
        // Polled, not observed: the new appearance must have taken over before its tiles appear.
        try await world.until { () async in films.isOnScreen }
        films.prefetchWindow(from: 0, lookahead: 2)
        films.prefetchWindow(from: 1, lookahead: 2)
        await hold.open()
        await firstScreen.value
        films.prefetchWindow(from: 4, lookahead: 0)
        try await world.until { () async in world.requestedFiles.count == 6 }
        secondScreen.cancel()

        #expect(world.requestedFiles.sorted() == [
            "Film 1.wmv", "Film 1.wmv", "Film 2.wmv", "Film 3.wmv", "Film 4.wmv", "Film 5.wmv",
        ])
    }

    /// A share whose root holds a Films folder plus Alpha and Omega, with Film 1 to Film 8 listed in
    /// that order inside Films. The NAS answers slowly enough to class as WAN, so one thumbnail
    /// generates at a time; the returned gate parks each decode once the thumbnailer has recorded it.
    private static func launchOverWAN() async throws -> (AppWorld, AsyncGate) {
        let world = try await AppWorld.launch(savedSMB: [(AppWorld.smbServer, "hunter2")])
        world.nas.setLatency(.milliseconds(400), host: AppWorld.smbServer.host)
        world.nas.setFolder([
            SMBDirectoryEntry(name: "Films", isDirectory: true, size: 0, modifiedAt: nil),
            SMBDirectoryEntry(name: "Alpha.wmv", isDirectory: false, size: 4096, modifiedAt: Date(timeIntervalSince1970: 2)),
            SMBDirectoryEntry(name: "Omega.wmv", isDirectory: false, size: 4096, modifiedAt: Date(timeIntervalSince1970: 1)),
        ], share: "Media")
        world.nas.setFolder((1...8).map {
            SMBDirectoryEntry(name: "Film \($0).wmv", isDirectory: false, size: 4096, modifiedAt: Date(timeIntervalSince1970: TimeInterval(100 - $0)))
        }, share: "Media", path: "Films")
        world.nas.setContents(Data(repeating: 0, count: 4096))
        let hold = AsyncGate(open: false)
        world.thumbnailer.hold = hold
        return (world, hold)
    }

    private static func key(of item: Item, ref: SMBServerRef) throws -> SMBThumbnailKey {
        guard case .movie(let movie) = item, let (share, path) = SMBSourceResolver.shareAndPath(for: item) else {
            throw StateNotFound()
        }
        return SMBThumbnailKey(
            serverID: ref.id.rawValue, share: share, path: path, size: movie.size ?? 0, modifiedAt: movie.dateAdded)
    }

    private static func addFile(_ name: String, to world: AppWorld, ref: SMBServerRef) async throws -> Item {
        world.nas.setFolder([
            SMBDirectoryEntry(name: "Heat.wmv", isDirectory: false, size: 4096, modifiedAt: nil),
            SMBDirectoryEntry(name: name, isDirectory: false, size: 4096, modifiedAt: nil),
        ], share: "Media")
        let root = await world.openSMBFolder(ref, share: "Media")
        try await world.until { root.media.count == 2 }
        return try #require(root.media.first { "\($0.id)".contains(name) })
    }

    private struct StateNotFound: Error {}

    private static func openHeat(
        contents: Data = Data(repeating: 0, count: 4096)
    ) async throws -> (AppWorld, MediaArtworkProvider, Item, SMBServerRef) {
        let ref = AppWorld.smbRef
        let world = try await AppWorld.launch(savedSMB: [(AppWorld.smbServer, "hunter2")])
        world.nas.setFolder([
            SMBDirectoryEntry(name: "Heat.wmv", isDirectory: false, size: 4096, modifiedAt: nil),
        ], share: "Media")
        world.nas.setContents(contents)
        let root = await world.openSMBFolder(ref, share: "Media")
        try await world.until { root.media.count == 1 }
        return (world, world.app.services.mediaArtworkProvider, root.media[0], ref)
    }

    /// Which test frame the tile shows: "scene", "mosaic", or "none".
    private static func frame(of artwork: MediaArtwork) -> String {
        guard case .local(let url) = artwork.source else { return "none" }
        switch try? Data(contentsOf: url) {
        case TestFrames.scene: return "scene"
        case TestFrames.mosaic: return "mosaic"
        default: return "unknown"
        }
    }
}

private extension AppWorld {
    /// Puts a level of the Media share on screen, as `SMBBrowseView`'s `.task` does. Cancelling the
    /// returned task is SwiftUI taking the level off screen.
    func showSMBLevel(_ path: String) -> (SMBBrowseViewModel, Task<Void, Never>) {
        showSMBLevel(app.makeSMBBrowse(SMBBrowsePath(ref: AppWorld.smbRef, share: "Media", path: path)))
    }

    /// Puts an already built level back on screen, as popping back to it does.
    func showSMBLevel(_ level: SMBBrowseViewModel) -> (SMBBrowseViewModel, Task<Void, Never>) {
        (level, Task { await level.appear() })
    }

    /// Takes a level off screen the way pushing past it or popping it does: SwiftUI cancels its
    /// `.task` and runs its `onDisappear`.
    func leave(_ level: SMBBrowseViewModel, _ screen: Task<Void, Never>) {
        screen.cancel()
        level.isOnScreen = false
    }

    /// The file names the frame thumbnailer was asked to decode, in order.
    var requestedFiles: [String] { thumbnailer.requests.map(\.lastPathComponent) }
}
