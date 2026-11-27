import Foundation
import ParallaxCore
import ParallaxCoreTestSupport
@testable import ParallaxFeatures
import ParallaxFileBrowse
import ParallaxFileBrowseTestSupport
import ParallaxJellyfin
import ParallaxPlaybackTestSupport
import Testing

@MainActor
@Suite("SMB artwork", .timeLimit(.minutes(1)))
struct SMBArtworkScenarios {
    @Test("thumbnail generation waits while the player is on screen and finishes once it closes")
    func generationPausesUnderThePlayer() async throws {
        let world = try await AppWorld.launch(savedSMB: [(AppWorld.smbServer, "hunter2")])
        world.nas.setFolder([
            SMBDirectoryEntry(name: "Heat.mp4", isDirectory: false, size: 4096, modifiedAt: nil),
            SMBDirectoryEntry(name: "Ran.mp4", isDirectory: false, size: 4096, modifiedAt: nil),
        ], share: "Media")
        world.nas.setContents(AppWorld.mp4Bytes)
        let provider = world.app.services.mediaArtworkProvider
        let root = await world.openSMBFolder(AppWorld.smbRef, share: "Media")
        try await world.until { root.media.count == 2 }
        let (heat, ran) = (root.media[0], root.media[1])

        root.play(ran)
        try await world.until { await provider.isPausedForPlayback }
        let tile = Task { await provider.artwork(for: heat, ref: AppWorld.smbRef, sidecar: nil) }
        try await world.until { await provider.generationsPausedForPlayback == 1 }
        #expect(world.thumbnailer.grabs == 0)

        world.app.playback.dismiss()
        try await world.clock.waitForSleep(dueIn: .milliseconds(600))
        world.clock.advance(by: .milliseconds(600))
        let artwork = await tile.value

        #expect(artwork.duration == .seconds(42))
        #expect(world.thumbnailer.grabs == 1)
        #expect(await provider.isPausedForPlayback == false)
    }

    @Test("a poster that never finishes downloading is dropped at its ceiling, and the tile falls back to a frame grab")
    func hungSidecarFallsBackToAFrameGrab() async throws {
        let world = try await AppWorld.launch(savedSMB: [(AppWorld.smbServer, "hunter2")])
        world.nas.setFolder([
            SMBDirectoryEntry(name: "Heat.mp4", isDirectory: false, size: 4096, modifiedAt: nil),
            SMBDirectoryEntry(name: "Heat-poster.jpg", isDirectory: false, size: 512, modifiedAt: nil),
        ], share: "Media")
        world.nas.setContents(AppWorld.mp4Bytes)
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
        #expect(world.thumbnailer.grabs == 1)
    }

    @Test("a file the thumbnailer cannot read shows no artwork, and its failure is remembered")
    func unreadableByTheThumbnailerIsRemembered() async throws {
        let (world, provider, heat, ref) = try await Self.openHeat()
        world.thumbnailer.failingDecodes = 1

        let artwork = await provider.artwork(for: heat, ref: ref, sidecar: nil)

        #expect(Self.frame(of: artwork) == "none")
        #expect(world.thumbnailer.grabs == 1)
        #expect(await world.thumbnailCache().failureState(for: try Self.key(of: heat, ref: ref)) != nil)
    }

    @Test("a grab whose reads stall gives up at its deadline, and its file is remembered as failed")
    func stalledGrabGivesUpAtItsDeadline() async throws {
        let (world, provider, heat, ref) = try await Self.openHeat()
        let listed = await world.nas.operationGate.arrivalCount
        await world.nas.operationGate.close()

        let tile = Task { await provider.artwork(for: heat, ref: ref, sidecar: nil) }
        await world.nas.operationGate.awaitArrivals(listed + 1)
        try await world.clock.waitForSleep(dueIn: .seconds(30))
        world.clock.advance(by: .seconds(30))
        let artwork = await tile.value
        await world.nas.operationGate.open()

        #expect(Self.frame(of: artwork) == "none")
        #expect(await world.thumbnailCache().failureState(for: try Self.key(of: heat, ref: ref)) != nil)
    }

    /// The ceiling's sleep is still waiting after the cancellation: the tile waits for its read.
    @Test("a tile cancelled while its read is stuck finishes at the deadline, and its file is not remembered as failed")
    func cancelledStuckGrabWaitsForItsDeadline() async throws {
        let (world, provider, heat, ref) = try await Self.openHeat()
        let listed = await world.nas.operationGate.arrivalCount
        await world.nas.operationGate.close()

        let tile = Task { await provider.artwork(for: heat, ref: ref, sidecar: nil) }
        await world.nas.operationGate.awaitArrivals(listed + 1)
        tile.cancel()
        try await world.clock.waitForSleep(dueIn: .seconds(30))
        world.clock.advance(by: .seconds(30))
        let artwork = await tile.value
        await world.nas.operationGate.open()

        #expect(Self.frame(of: artwork) == "none")
        #expect(await world.thumbnailCache().failureState(for: try Self.key(of: heat, ref: ref)) == nil)
    }

    @Test("a grab whose tile is cancelled stops, and its file is not remembered as failed")
    func cancelledGrabIsNotRemembered() async throws {
        let (world, provider, heat, ref) = try await Self.openHeat()
        let hold = AsyncGate(open: false)
        world.thumbnailer.hold = hold

        let tile = Task { await provider.artwork(for: heat, ref: ref, sidecar: nil) }
        await hold.awaitArrivals(1)
        tile.cancel()
        await hold.open()
        let artwork = await tile.value

        #expect(Self.frame(of: artwork) == "none")
        #expect(await world.thumbnailCache().failureState(for: try Self.key(of: heat, ref: ref)) == nil)
    }

    @Test("a thumbnail that finishes or is cancelled hands its connection back, so the next file's thumbnail opens no new one",
          arguments: [false, true])
    func thumbnailReturnsItsConnection(cancelled: Bool) async throws {
        let (world, provider, heat, ref) = try await Self.openHeat()
        let ran = try await Self.addFile("Ran.mp4", to: world, ref: ref)
        let hold = AsyncGate(open: !cancelled)
        world.thumbnailer.hold = hold
        let first = Task { await provider.artwork(for: heat, ref: ref, sidecar: nil) }
        if cancelled {
            await hold.awaitArrivals(1)
            first.cancel()
            await hold.open()
        }
        _ = await first.value
        let connects = world.nas.connectAttempts

        let artwork = await provider.artwork(for: ran, ref: ref, sidecar: nil)

        #expect(Self.frame(of: artwork) == "scene")
        #expect(world.nas.connectAttempts == connects)
    }

    @Test("after the update, a file whose thumbnail failed under the old route gets one the next time it is on screen")
    func oldRouteFailureIsRetried() async throws {
        let (world, provider, heat, ref) = try await Self.openHeat()
        let marker = try world.leaveOldRouteFailureMarker(for: try Self.key(of: heat, ref: ref))

        let artwork = await provider.artwork(for: heat, ref: ref, sidecar: nil)

        #expect(Self.frame(of: artwork) == "scene")
        #expect(!FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)))
    }

    @Test("a file the share refuses to open is remembered as failed, so its tile is not probed again on every scroll")
    func unreadableFileBacksOff() async throws {
        let (world, provider, heat, ref) = try await Self.openHeat()
        world.nas.setFileSizeOutcome(.fails(POSIXError(.EACCES)))

        let artwork = await provider.artwork(for: heat, ref: ref, sidecar: nil)
        let nextScroll = await provider.artwork(for: heat, ref: ref, sidecar: nil)

        #expect(Self.frame(of: artwork) == "none")
        #expect(Self.frame(of: nextScroll) == "none")
        #expect(world.nas.readPaths == ["Heat.mp4"])
        #expect(await world.thumbnailCache().failureState(for: try Self.key(of: heat, ref: ref)) != nil)
    }

    @Test("a file whose frame fails to decode shows no artwork and is not grabbed again within its backoff")
    func undecodableFileBacksOff() async throws {
        let (world, provider, heat, ref) = try await Self.openHeat()
        world.thumbnailer.failingDecodes = 1

        let first = await provider.artwork(for: heat, ref: ref, sidecar: nil)
        let withinBackoff = await provider.artwork(for: heat, ref: ref, sidecar: nil)

        #expect(Self.frame(of: first) == "none")
        #expect(Self.frame(of: withinBackoff) == "none")
        #expect(world.thumbnailer.grabs == 1)
    }

    /// The backoff outlives the process on the failure marker, so a relaunched provider reads it
    /// from disk; the scenario's clock has to drive that read like the in-memory one.
    @Test("a file whose frame failed to decode is grabbed again once its backoff runs out, across a relaunch, and the good frame is cached")
    func backoffRunsOutAcrossARelaunch() async throws {
        let (world, provider, heat, ref) = try await Self.openHeat()
        world.thumbnailer.failingDecodes = 1
        let failed = await provider.artwork(for: heat, ref: ref, sidecar: nil)

        await world.relaunch()
        let relaunched = world.app.services.mediaArtworkProvider
        let withinBackoff = await relaunched.artwork(for: heat, ref: ref, sidecar: nil)
        world.clock.advance(by: .seconds(180))
        let afterBackoff = await relaunched.artwork(for: heat, ref: ref, sidecar: nil)
        let revisit = await relaunched.artwork(for: heat, ref: ref, sidecar: nil)

        #expect(Self.frame(of: failed) == "none")
        #expect(Self.frame(of: withinBackoff) == "none")
        #expect(Self.frame(of: afterBackoff) == "scene")
        #expect(Self.frame(of: revisit) == "scene")
        #expect(world.thumbnailer.grabs == 2)
    }

    @Test("a poster cached by the sidecar tier is served across a relaunch without a re-download")
    func posterSurvivesRelaunch() async throws {
        let ref = AppWorld.smbRef
        let world = try await AppWorld.launch(savedSMB: [(AppWorld.smbServer, "hunter2")])
        world.nas.setFolder([
            SMBDirectoryEntry(name: "Heat.mp4", isDirectory: false, size: 4096, modifiedAt: nil),
            SMBDirectoryEntry(name: "Heat-poster.jpg", isDirectory: false, size: Int64(TestFrames.scene.count), modifiedAt: nil),
        ], share: "Media")
        world.nas.setContents(TestFrames.scene)
        let root = await world.openSMBFolder(ref, share: "Media")
        try await world.until { root.media.count == 1 }
        let heat = root.media[0]
        let poster = try #require(root.artwork[heat.id])
        _ = await world.app.services.mediaArtworkProvider.artwork(for: heat, ref: ref, sidecar: poster)
        #expect(world.thumbnailer.grabs == 0)

        let relaunched = world.thumbnailCache()
        #expect(await relaunched.existing(for: try Self.key(of: heat, ref: ref)) != nil)
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
        try await world.until { () async in world.requestedFiles.contains("Omega.mp4") }
        _ = await alphaAgain.value
        rootAgain.cancel()

        #expect(world.requestedFiles.sorted() == ["Alpha.mp4", "Alpha.mp4", "Omega.mp4"])
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
            "Film 1.mp4", "Film 2.mp4", "Film 3.mp4", "Film 4.mp4", "Film 6.mp4", "Film 7.mp4", "Film 8.mp4",
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
            "Film 1.mp4", "Film 1.mp4", "Film 2.mp4", "Film 3.mp4", "Film 4.mp4", "Film 5.mp4",
        ])
    }

    /// A share whose root holds a Films folder plus Alpha and Omega, with Film 1 to Film 8 listed in
    /// that order inside Films. The NAS answers slowly enough to class as WAN, so one thumbnail
    /// generates at a time; the returned gate parks each grab once the thumbnailer has counted it.
    private static func launchOverWAN() async throws -> (AppWorld, AsyncGate) {
        let world = try await AppWorld.launch(savedSMB: [(AppWorld.smbServer, "hunter2")])
        world.nas.setLatency(.milliseconds(400), host: AppWorld.smbServer.host)
        world.nas.setFolder([
            SMBDirectoryEntry(name: "Films", isDirectory: true, size: 0, modifiedAt: nil),
            SMBDirectoryEntry(name: "Alpha.mp4", isDirectory: false, size: 4096, modifiedAt: Date(timeIntervalSince1970: 2)),
            SMBDirectoryEntry(name: "Omega.mp4", isDirectory: false, size: 4096, modifiedAt: Date(timeIntervalSince1970: 1)),
        ], share: "Media")
        world.nas.setFolder((1...8).map {
            SMBDirectoryEntry(name: "Film \($0).mp4", isDirectory: false, size: 4096, modifiedAt: Date(timeIntervalSince1970: TimeInterval(100 - $0)))
        }, share: "Media", path: "Films")
        world.nas.setContents(AppWorld.mp4Bytes)
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
            SMBDirectoryEntry(name: "Heat.mp4", isDirectory: false, size: 4096, modifiedAt: nil),
            SMBDirectoryEntry(name: name, isDirectory: false, size: 4096, modifiedAt: nil),
        ], share: "Media")
        let root = await world.openSMBFolder(ref, share: "Media")
        try await world.until { root.media.count == 2 }
        return try #require(root.media.first { "\($0.id)".contains(name) })
    }

    private struct StateNotFound: Error {}

    private static func openHeat(
        contents: Data = AppWorld.mp4Bytes
    ) async throws -> (AppWorld, MediaArtworkProvider, Item, SMBServerRef) {
        let ref = AppWorld.smbRef
        let world = try await AppWorld.launch(savedSMB: [(AppWorld.smbServer, "hunter2")])
        world.nas.setFolder([
            SMBDirectoryEntry(name: "Heat.mp4", isDirectory: false, size: 4096, modifiedAt: nil),
        ], share: "Media")
        world.nas.setContents(contents)
        let root = await world.openSMBFolder(ref, share: "Media")
        try await world.until { root.media.count == 1 }
        return (world, world.app.services.mediaArtworkProvider, root.media[0], ref)
    }

    /// Which test frame the tile shows: "scene", or "none".
    private static func frame(of artwork: MediaArtwork) -> String {
        guard case .local(let url) = artwork.source else { return "none" }
        switch try? Data(contentsOf: url) {
        case TestFrames.scene: return "scene"
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

    /// The files the thumbnailer was handed, in order: in these scenarios nothing else reads the
    /// share.
    var requestedFiles: [String] { nas.readPaths.map { ($0 as NSString).lastPathComponent } }
}
