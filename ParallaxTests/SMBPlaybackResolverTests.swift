import Foundation
import Testing
import CoreMedia
import ParallaxCore
import ParallaxJellyfin
import ParallaxFileBrowse
@testable import Parallax

// MARK: - In-test fake lister

/// Minimal `SMBLister` fake that returns a fixed set of entries on every call.
private final class StubSMBLister: SMBLister, @unchecked Sendable {
    let entries: [SMBDirectoryEntry]
    var shouldThrow = false

    init(entries: [SMBDirectoryEntry]) {
        self.entries = entries
    }

    func listShares() async throws -> [SMBShare] { [] }

    func list(share: String, path: String) async throws -> [SMBDirectoryEntry] {
        if shouldThrow { throw StubError.listFailed }
        return entries
    }

    func disconnect() async {}

    enum StubError: Error { case listFailed }
}

// MARK: - Test fixtures

private func makeRef(
    id: String = "smb-nas.local|Media|Movies",
    host: String = "nas.local",
    share: String = "Media",
    username: String = "alice",
    domain: String = "WORKGROUP"
) -> SMBServerRef {
    SMBServerRef(
        id: ServerID(rawValue: id),
        data: SMBServerData(host: host, username: username, domain: domain, shares: [share])
    )
}

/// Returns a `.movie` `Item` whose `ItemID` is encoded the same way `SMBMediaRepository` encodes it.
/// `rawID` overrides the encoded id outright — used to mint an undecodable (no `share:path` colon) id.
private func makeItem(share: String = "Media", path: String = "Movies/Example.mkv", rawID: String? = nil) -> Item {
    let title = (path as NSString).lastPathComponent
    let displayTitle = (title as NSString).deletingPathExtension
    let movie = Movie(
        id: ItemID(rawValue: rawID ?? "\(share):\(path)"),
        title: displayTitle,
        overview: nil,
        year: nil,
        runtime: nil,
        communityRating: nil,
        officialRating: nil,
        genres: [],
        primaryTag: nil,
        backdropTags: [],
        logoTag: nil,
        thumbTag: nil,
        dateAdded: nil,
        userData: UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: false),
        width: nil,
        height: nil,
        videoRangeType: nil,
        hasSubtitles: false
    )
    return .movie(movie)
}

// MARK: - Tests

@Suite("SMBPlaybackResolver")
struct SMBPlaybackResolverTests {

    // MARK: - Helpers

    private func makeResolver(
        keychain: FakeKeychain = FakeKeychain(),
        lister: StubSMBLister,
        resumeStore: SMBResumeStore = .shared
    ) -> SMBPlaybackResolver {
        var resolver = SMBPlaybackResolver(keychain: keychain) { _, _ in lister }
        resolver.resumeStore = resumeStore
        return resolver
    }

    /// Isolated defaults per test — mirrors `SMBResumeStoreTests`' hygiene so these tests
    /// never touch `UserDefaults.standard`.
    private func makeResumeStore(suite: String) throws -> (store: SMBResumeStore, defaults: UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (SMBResumeStore(defaults: defaults), defaults)
    }

    // MARK: - URL

    @Test("resolved URL is smb://host/share/path with no credentials embedded")
    func urlIsCredentialFree() async throws {
        let lister = StubSMBLister(entries: [])
        let resolver = makeResolver(lister: lister)
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
        let keychain = FakeKeychain()
        try keychain.setValue("s3cr3t", for: KeychainKey<String>(account: "token-smb-nas.local|Media|Movies"))

        let lister = StubSMBLister(entries: [])
        let resolver = makeResolver(keychain: keychain, lister: lister)
        let item = makeItem()
        let ref = makeRef()

        let result = try await resolver.resolve(item, ref: ref)

        #expect(result.vlcOptions == [":smb-user=alice", ":smb-pwd=s3cr3t", ":smb-domain=WORKGROUP"])
    }

    @Test("missing Keychain entry falls back to empty password without throwing")
    func missingPasswordFallsBack() async throws {
        let lister = StubSMBLister(entries: [])
        let resolver = makeResolver(lister: lister)   // keychain has no entry
        let item = makeItem()
        let ref = makeRef()

        let result = try await resolver.resolve(item, ref: ref)

        #expect(result.vlcOptions == [":smb-user=alice", ":smb-pwd=", ":smb-domain=WORKGROUP"])
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
        let lister = StubSMBLister(entries: entries)
        let resolver = makeResolver(lister: lister)
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
        let lister = StubSMBLister(entries: [])
        lister.shouldThrow = true
        let resolver = makeResolver(lister: lister)
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
        let lister = StubSMBLister(entries: [])
        let resolver = makeResolver(lister: lister)
        let item = makeItem(share: "Media", path: "Movies/Example.mkv")
        let ref = makeRef()

        let result = try await resolver.resolve(item, ref: ref)

        #expect(result.title == "Example")
    }

    // MARK: - Invalid ItemID

    @Test("undecodable ItemID (no share:path separator) throws AppError.source(.notFound)")
    func undecodableItemIDThrows() async throws {
        let lister = StubSMBLister(entries: [])
        let resolver = makeResolver(lister: lister)
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
        let suite = "SMBPlaybackResolverTests.startTimeNilWithoutStoredResume"
        let (store, defaults) = try makeResumeStore(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let lister = StubSMBLister(entries: [])
        let resolver = makeResolver(lister: lister, resumeStore: store)
        let item = makeItem()
        let ref = makeRef()

        let result = try await resolver.resolve(item, ref: ref)

        #expect(result.startTime == nil)
    }

    @Test("startTime comes from the local resume store when it holds a position")
    func startTimeFromStoredResume() async throws {
        let suite = "SMBPlaybackResolverTests.startTimeFromStoredResume"
        let (store, defaults) = try makeResumeStore(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let lister = StubSMBLister(entries: [])
        let resolver = makeResolver(lister: lister, resumeStore: store)
        let item = makeItem(path: "Movies/Resumable.mkv")
        let ref = makeRef()
        await store.save(
            position: CMTime(seconds: 300, preferredTimescale: 600),
            duration: CMTime(seconds: 7200, preferredTimescale: 600),
            for: item.id
        )

        let result = try await resolver.resolve(item, ref: ref)

        let startTime = try #require(result.startTime)
        #expect(abs(CMTimeGetSeconds(startTime) - 300) < 0.001)
    }

    // MARK: - Root-level path (no directory)

    @Test("path with no directory component produces correct URL and resolves subs from share root")
    func rootLevelPath() async throws {
        let entries: [SMBDirectoryEntry] = [
            .init(name: "Standalone.mkv",    isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "Standalone.en.srt", isDirectory: false, size: 1, modifiedAt: nil),
        ]
        let lister = StubSMBLister(entries: entries)
        let resolver = makeResolver(lister: lister)
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
