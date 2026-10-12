import Foundation
import Testing
import CoreMedia
import ParallaxCore
import ParallaxJellyfin
import ParallaxFileBrowse
import ParallaxFileBrowseTestSupport
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

/// The one NAS every test here resolves against, under the id `addSMBServer` derives for its host.
private func makeRef(share: String = "Media") -> SMBServerRef {
    makeSMBRef(id: "smb-nas.local", shares: [share])
}

/// Returns a `.movie` `Item` whose `ItemID` is encoded the same way `SMBMediaRepository` encodes it.
/// `rawID` overrides the encoded id outright — used to mint an undecodable (no `share:path` colon) id.
private func makeItem(share: String = "Media", path: String = "Movies/Example.mkv", rawID: String? = nil) -> Item {
    let title = (path as NSString).lastPathComponent
    let displayTitle = (title as NSString).deletingPathExtension
    return makeMovieItem(rawID ?? "\(share):\(path)", title: displayTitle)
}

// MARK: - Tests

@Suite("SMBPlaybackResolver")
struct SMBPlaybackResolverTests {

    // MARK: - Helpers

    /// Builds a resolver over an isolated `ServerStore`. `seedPassword` saves `makeRef()`'s server
    /// through `addSMBServer`, the production write path, so the slot is wherever the resolver
    /// reads it from. The default `""` mirrors a stored guest password; pass `nil` to leave the slot
    /// empty, which the resolver must surface as `.auth(.credentialUnavailable)`.
    /// `resumeStore` defaults to a throwaway isolated store, NOT `SMBResumeStore.shared`: the shared
    /// one reads and writes the real `UserDefaults.standard` domain, so every test that didn't pass
    /// its own store was touching (and could inherit) live app state.
    private func makeResolver(
        seedPassword: String? = "",
        listing: SiblingListing,
        resumeStore: SMBResumeStore? = nil
    ) async throws -> SMBPlaybackResolver {
        let store = makeIsolatedServerStore(label: "SMBPlaybackResolverTests")
        if let seedPassword {
            let id = try await store.addSMBServer(makeRef().data, password: seedPassword)
            try #require(id == makeRef().id, "makeRef()'s id must be the one addSMBServer derives")
        }
        let world = FakeSMBWorld()
        // No file bytes are readable, so the container probe fails and every resolve takes the
        // smb:// route these suites pin.
        world.setFileSizeOutcome(.fails(POSIXError(.ECONNREFUSED)))
        world.setListingOutcome(listing.shouldThrow ? .fails(SiblingListing.StubError.listFailed) : .entries(listing.entries))
        return SMBPlaybackResolver(
            serverStore: store,
            connections: world.connections(),
            resumeStore: resumeStore ?? SMBTestFixtures.inertResumeStore()
        )
    }

    // MARK: - URL

    @Test("resolved URL is smb://host/share/path with no credentials embedded")
    func urlIsCredentialFree() async throws {
        let listing = SiblingListing(entries: [])
        let resolver = try await makeResolver(listing: listing)
        let item = makeItem(share: "Media", path: "Movies/Example.mkv")
        let ref = makeRef()

        let result = try await resolver.resolve(item, ref: ref)

        #expect(result.url.absoluteString == "smb://nas.local/Media/Movies/Example.mkv")
        #expect(!result.url.absoluteString.contains("@"), "URL must not contain credential separator")
        #expect(!result.url.absoluteString.contains("alice"))
    }

    // MARK: - VLC credential options

    @Test("vlcOptions contain the three smb credential strings with the seeded password")
    func vlcOptionsCarryCredentials() async throws {
        let listing = SiblingListing(entries: [])
        let resolver = try await makeResolver(seedPassword: "s3cr3t", listing: listing)
        let item = makeItem()
        let ref = makeRef()

        let result = try await resolver.resolve(item, ref: ref)

        #expect(result.vlcOptions == [":smb-user=alice", ":smb-pwd=s3cr3t", ":smb-domain=WORKGROUP"])
    }

    @Test("stored-empty guest password resolves with an empty smb-pwd option")
    func storedEmptyGuestPasswordResolves() async throws {
        let listing = SiblingListing(entries: [])
        let resolver = try await makeResolver(listing: listing)   // default seed: stored ""
        let item = makeItem()
        let ref = makeRef()

        let result = try await resolver.resolve(item, ref: ref)

        #expect(result.vlcOptions == [":smb-user=alice", ":smb-pwd=", ":smb-domain=WORKGROUP"])
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

    @Test("subtitleURLs contains matched sidecar and excludes unrelated files")
    func subtitleURLsContainsMatchedSidecar() async throws {
        // Sibling entries alongside "Example.mkv":
        //   Example.en.srt  → matches (language token "en")
        //   readme.txt      → not a subtitle extension, excluded
        //   Other.srt       → unrelated filename, excluded by STRICT matching
        //   Sibling.mkv     → a second video, so the listing is NOT a lonely-video folder; that keeps
        //                     the tiered matcher's lonely-video fallback OFF, so "Other.srt" (which
        //                     matches no video by name) is correctly excluded rather than cross-attached.
        let entries: [SMBDirectoryEntry] = [
            .init(name: "Example.mkv",    isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "Sibling.mkv",    isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "Example.en.srt", isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "readme.txt",     isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "Other.srt",      isDirectory: false, size: 1, modifiedAt: nil),
        ]
        let listing = SiblingListing(entries: entries)
        let resolver = try await makeResolver(listing: listing)
        let item = makeItem(share: "Media", path: "Movies/Example.mkv")
        let ref = makeRef()

        let result = try await resolver.resolve(item, ref: ref)

        #expect(result.subtitleURLs.count == 1)
        let subURL = try #require(result.subtitleURLs.values.first)
        #expect(subURL.lastPathComponent == "Example.en.srt")
        // Verify the smb:// URL shape
        #expect(subURL.absoluteString == "smb://nas.local/Media/Movies/Example.en.srt")
    }

    @Test("subtitle resolution throwing yields empty subtitleURLs and playback item is still returned")
    func subtitleThrowingYieldsEmptyMap() async throws {
        let listing = SiblingListing(entries: [])
        listing.shouldThrow = true
        let resolver = try await makeResolver(listing: listing)
        let item = makeItem()
        let ref = makeRef()

        // Must NOT throw — subtitle errors are non-fatal.
        let result = try await resolver.resolve(item, ref: ref)

        #expect(result.subtitleURLs.isEmpty)
        #expect(result.url.absoluteString == "smb://nas.local/Media/Movies/Example.mkv")
    }

    // MARK: - Title

    @Test("title is the item's displayTitle (filename without extension)")
    func titleIsDisplayTitle() async throws {
        let listing = SiblingListing(entries: [])
        let resolver = try await makeResolver(listing: listing)
        let item = makeItem(share: "Media", path: "Movies/Example.mkv")
        let ref = makeRef()

        let result = try await resolver.resolve(item, ref: ref)

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

            #expect(result.startTime == nil)
        }
    }

    @Test("startTime comes from the local resume store when it holds a position")
    func startTimeFromStoredResume() async throws {
        try await SMBTestFixtures.withResumeStore(suite: #function) { store in
            let resolver = try await makeResolver(listing: SiblingListing(entries: []), resumeStore: store)
            let item = makeItem(path: "Movies/Resumable.mkv")
            await store.save(
                position: CMTime(seconds: 300, preferredTimescale: 600),
                duration: CMTime(seconds: 7200, preferredTimescale: 600),
                for: item.id
            )

            let result = try await resolver.resolve(item, ref: makeRef())

            let startTime = try #require(result.startTime)
            #expect(abs(CMTimeGetSeconds(startTime) - 300) < 0.001)
        }
    }

    // MARK: - Root-level path (no directory)

    @Test("path with no directory component produces correct URL and resolves subs from share root")
    func rootLevelPath() async throws {
        let entries: [SMBDirectoryEntry] = [
            .init(name: "Standalone.mkv",    isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "Standalone.en.srt", isDirectory: false, size: 1, modifiedAt: nil),
        ]
        let listing = SiblingListing(entries: entries)
        let resolver = try await makeResolver(listing: listing)
        // ItemID encodes root="" → path is just the filename
        let item = makeItem(share: "Media", path: "Standalone.mkv")
        let ref = makeRef(share: "Media")

        let result = try await resolver.resolve(item, ref: ref)

        #expect(result.url.absoluteString == "smb://nas.local/Media/Standalone.mkv")
        #expect(result.subtitleURLs.count == 1)
        let subURL = try #require(result.subtitleURLs.values.first)
        #expect(subURL.lastPathComponent == "Standalone.en.srt")
    }
}
