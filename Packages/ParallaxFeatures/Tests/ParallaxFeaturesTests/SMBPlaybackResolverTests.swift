import Foundation
import Testing
import CoreMedia
import ParallaxCore
import ParallaxJellyfin
import ParallaxFileBrowse
import ParallaxFileBrowseTestSupport
import ParallaxPlayback
import ParallaxPlaybackTestSupport
import ParallaxCoreTestSupport
@testable import ParallaxFeatures

// MARK: - Scripted sibling listing

/// What the video's folder lists, on every call. The resolver lists it through the real pooled
/// lister over `FakeSMBWorld`.
private final class SiblingListing {
    let entries: [SMBDirectoryEntry]
    var shouldThrow = false

    init(entries: [SMBDirectoryEntry]) {
        self.entries = entries
    }

    enum StubError: Error { case listFailed }
}

// MARK: - Test fixtures

/// The one NAS every test here resolves against.
private func makeRef(share: String = "Media") -> SMBServerRef {
    makeSMBRef(makeSMBServerData(shares: [share]))
}

/// Returns a `.movie` `Item` whose `ItemID` is encoded the same way `SMBMediaRepository` encodes it.
/// `rawID` overrides the encoded id outright — used to mint an undecodable (no `share:path` colon) id.
private func makeItem(share: String = "Media", path: String = "Movies/Example.mp4", rawID: String? = nil) -> Item {
    let title = (path as NSString).lastPathComponent
    let displayTitle = (title as NSString).deletingPathExtension
    return makeMovieItem(rawID ?? "\(share):\(path)", title: displayTitle)
}

// MARK: - Tests

@Suite("SMBPlaybackResolver", .timeLimit(.minutes(1)))
struct SMBPlaybackResolverTests {

    // MARK: - Helpers

    /// Builds a resolver over an isolated `ServerStore`. `seedPassword` saves `makeRef()`'s server
    /// through `addSMBServer`, the production write path, so the slot is wherever the resolver
    /// reads it from. The default `""` mirrors a stored guest password; pass `nil` to leave the slot
    /// empty, which the resolver must surface as `.auth(.credentialUnavailable)`.
    /// `resumeStore` defaults to a throwaway isolated store, NOT `SMBResumeStore.shared`: the shared
    /// one reads and writes the real `UserDefaults.standard` domain, so every test that didn't pass
    /// its own store was touching (and could inherit) live app state.
    /// `contents` is the file the share serves; nil makes the share refuse the file's stat.
    private func makeResolver(
        seedPassword: String? = "",
        listing: SiblingListing,
        resumeStore: SMBResumeStore? = nil,
        contents: Data? = AppWorld.mp4Bytes,
        world: FakeSMBWorld? = nil
    ) async throws -> SMBPlaybackResolver {
        let store = makeIsolatedServerStore(label: "SMBPlaybackResolverTests")
        if let seedPassword {
            let id = try await store.addSMBServer(makeRef().data, password: seedPassword)
            try #require(id == makeRef().id, "makeRef()'s id must be the one addSMBServer derives")
        }
        let clock = TestClock()
        let world = world ?? FakeSMBWorld(clock: clock)
        if let contents {
            world.setContents(contents)
        } else {
            world.setFileSizeOutcome(.fails(POSIXError(.ECONNREFUSED)))
        }
        world.setListingOutcome(listing.shouldThrow ? .fails(SiblingListing.StubError.listFailed) : .entries(listing.entries))
        return SMBPlaybackResolver(
            serverStore: store,
            connections: world.connections(),
            resumeStore: resumeStore ?? SMBTestFixtures.inertResumeStore(),
            clock: clock,
            deviceProfileBuilder: DeviceProfileBuilder(probe: FakeCapabilityProbe())
        )
    }

    // MARK: - URL

    @Test("the resolved URL is the local bridge's, naming the file and carrying no credentials")
    func urlIsCredentialFree() async throws {
        let resolver = try await makeResolver(seedPassword: "s3cr3t", listing: SiblingListing(entries: []))

        let result = try await resolver.resolve(makeItem(), ref: makeRef())
        await result.cleanup()

        #expect(result.url.scheme == "http")
        #expect(result.url.lastPathComponent == "Example.mp4")
        #expect(!result.url.absoluteString.contains("@"), "URL must not contain credential separator")
        #expect(!result.url.absoluteString.contains("alice"))
        #expect(!result.url.absoluteString.contains("s3cr3t"))
    }

    @Test("a stored-empty guest password resolves")
    func storedEmptyGuestPasswordResolves() async throws {
        let resolver = try await makeResolver(listing: SiblingListing(entries: []))   // default seed: stored ""

        let result = try await resolver.resolve(makeItem(), ref: makeRef())
        await result.cleanup()

        #expect(result.url.scheme == "http")
    }

    // MARK: - Files AVPlayer can't play directly

    /// Every played SMB file rides the bridge into AVPlayer, so a file the verdict refuses fails
    /// the resolve with the error the player shows, instead of opening a stream that can't play.
    @Test("a file AVPlayer can't play directly fails the resolve with the reason the player shows",
          arguments: [
            (Data?.none, AppError.source(.connectionLost)),
            (ISOBMFFFixtures.ftyp() + ISOBMFFFixtures.box("mdat", Data(count: 64)), .playback(.incompleteFile)),
            (AppWorld.mkvBytes, .playback(.unsupportedFormat(reason: "unreadable: unreadableContainer(code: -1094995529)"))),
            (Data(repeating: 0x5A, count: 64), .playback(.unsupportedFormat(reason: "container: unknown"))),
          ])
    func unplayableFileFailsTheResolve(contents: Data?, expected: AppError) async throws {
        let resolver = try await makeResolver(listing: SiblingListing(entries: []), contents: contents)

        do {
            let result = try await resolver.resolve(makeItem(), ref: makeRef())
            await result.cleanup()
            Issue.record("resolved \(result.url) for a file AVPlayer can't play")
        } catch let error as AppError {
            #expect(error.diagnosticDescription == expected.diagnosticDescription)
        }
    }

    @Test("a file that vanished since the listing fails as not found, not as a dropped connection")
    func vanishedFileFailsAsNotFound() async throws {
        let world = FakeSMBWorld(clock: TestClock())
        let resolver = try await makeResolver(listing: SiblingListing(entries: []), world: world)
        world.setFileSizeOutcome(.fails(POSIXError(.ENOENT)))

        do {
            let result = try await resolver.resolve(makeItem(), ref: makeRef())
            await result.cleanup()
            Issue.record("resolved \(result.url) for a file that is gone")
        } catch let error as AppError {
            #expect(error.diagnosticDescription == AppError.source(.notFound).diagnosticDescription)
        }
    }

    @Test("a played file's connection is dropped at cleanup, never returned to the pool")
    func playedFileDiscardsItsConnection() async throws {
        let world = FakeSMBWorld(clock: TestClock())
        let resolver = try await makeResolver(listing: SiblingListing(entries: []), world: world)

        let result = try await resolver.resolve(makeItem(), ref: makeRef())
        let before = world.disconnectedIDs
        await result.cleanup()

        await untilSettled { world.disconnectedIDs.count == before.count + 1 }
        #expect(world.useAfterFreeIDs.isEmpty)
    }

    @Test("missing Keychain slot throws .auth(.credentialUnavailable) instead of a guest logon")
    func missingPasswordThrowsCredentialUnavailable() async throws {
        // The lost-slot incident contract: addSMBServer always stores a password (even ""), so an
        // absent slot is data loss — the resolver must surface it, never impersonate a guest.
        let listing = SiblingListing(entries: [])
        let resolver = try await makeResolver(seedPassword: nil, listing: listing)
        let item = makeItem()
        let ref = makeRef()

        do {
            _ = try await resolver.resolve(item, ref: ref)
            Issue.record("Expected AppError.auth(.credentialUnavailable) to be thrown")
        } catch let error as AppError {
            guard case .auth(.credentialUnavailable) = error else {
                Issue.record("Expected .auth(.credentialUnavailable), got \(error)")
                return
            }
        }
    }

    // MARK: - Subtitle resolution

    // MARK: - Title

    @Test("title is the item's displayTitle (filename without extension)")
    func titleIsDisplayTitle() async throws {
        let listing = SiblingListing(entries: [])
        let resolver = try await makeResolver(listing: listing)
        let item = makeItem(share: "Media", path: "Movies/Example.mp4")
        let ref = makeRef()

        let result = try await resolver.resolve(item, ref: ref)
        await result.cleanup()

        #expect(result.title == "Example")
    }

    // MARK: - Invalid ItemID

    @Test("undecodable ItemID (no share:path separator) throws AppError.source(.notFound)")
    func undecodableItemIDThrows() async throws {
        let listing = SiblingListing(entries: [])
        let resolver = try await makeResolver(listing: listing)
        // After the share-hierarchy refactor the share rides in the ItemID, so a cross-share item
        // resolves against the id's own share (the ref no longer carries a single authoritative
        // share). The only un-resolvable id now is one that can't be decoded at all — no colon, so
        // `decodeItemID` returns nil → `.notFound`.
        let item = makeItem(rawID: "not-a-valid-smb-id")
        let ref = makeRef()

        do {
            _ = try await resolver.resolve(item, ref: ref)
            Issue.record("Expected AppError.source(.notFound) to be thrown")
        } catch let error as AppError {
            guard case .source(let failure) = error, case .notFound = failure else {
                Issue.record("Expected .source(.notFound), got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - startTime

    @Test("startTime is nil when the local resume store has no entry")
    func startTimeNilWithoutStoredResume() async throws {
        try await SMBTestFixtures.withResumeStore(suite: #function) { store in
            let resolver = try await makeResolver(listing: SiblingListing(entries: []), resumeStore: store)

            let result = try await resolver.resolve(makeItem(), ref: makeRef())
            await result.cleanup()

            #expect(result.startTime == nil)
        }
    }

    @Test("startTime comes from the local resume store when it holds a position")
    func startTimeFromStoredResume() async throws {
        try await SMBTestFixtures.withResumeStore(suite: #function) { store in
            let resolver = try await makeResolver(listing: SiblingListing(entries: []), resumeStore: store)
            let item = makeItem(path: "Movies/Resumable.mp4")
            await store.save(
                position: CMTime(seconds: 300, preferredTimescale: 600),
                duration: CMTime(seconds: 7200, preferredTimescale: 600),
                for: item.id
            )

            let result = try await resolver.resolve(item, ref: makeRef())
            await result.cleanup()

            let startTime = try #require(result.startTime)
            #expect(abs(CMTimeGetSeconds(startTime) - 300) < 0.001)
        }
    }

    // MARK: - Root-level path (no directory)

}
