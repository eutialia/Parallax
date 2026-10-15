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

    private static func openHeat() async throws -> (AppWorld, MediaArtworkProvider, Item, SMBServerRef) {
        let ref = AppWorld.smbRef
        let world = try await AppWorld.launch(savedSMB: [(AppWorld.smbServer, "hunter2")])
        world.nas.setFolder([
            SMBDirectoryEntry(name: "Heat.wmv", isDirectory: false, size: 4096, modifiedAt: nil),
        ], share: "Media")
        world.nas.setContents(Data(repeating: 0, count: 4096))
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
