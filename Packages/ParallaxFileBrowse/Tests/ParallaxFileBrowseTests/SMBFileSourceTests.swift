import Foundation
import Testing
import ParallaxCore
@testable import ParallaxFileBrowse

@Suite("SMBFileSource")
struct SMBFileSourceTests {

    // MARK: - Media filter

    @Test("SMBFileSource lists only top-level media files, excludes dirs/non-media")
    func filtersToTopLevelMedia() async throws {
        let lister = FakeSMBLister(entries: [
            .init(name: "A.mkv",    isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "B.mp4",    isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "poster.jpg", isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "readme.txt", isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "Season 1", isDirectory: true,  size: 0, modifiedAt: nil),
        ])
        let source = SMBFileSource(lister: lister, host: "nas", share: "Media", root: "")
        let files = try await source.mediaFiles(in: "")
        #expect(files.map(\.name).sorted() == ["A.mkv", "B.mp4"])
    }

    @Test("SMBFileSource excludes all directory entries regardless of extension")
    func excludesDirectories() async throws {
        let lister = FakeSMBLister(entries: [
            .init(name: "FakeDir.mkv", isDirectory: true,  size: 0, modifiedAt: nil),
            .init(name: "Real.m4v",    isDirectory: false, size: 1, modifiedAt: nil),
        ])
        let source = SMBFileSource(lister: lister, host: "nas", share: "Media", root: "")
        let files = try await source.mediaFiles(in: "")
        #expect(files.map(\.name) == ["Real.m4v"])
    }

    @Test("SMBFileSource accepts every whitelisted media extension")
    func recognisesAllMediaExtensions() async throws {
        // Drive from the real allowlist so this can't go stale when the set is widened.
        let extensions = Array(SMBFileSource.mediaExtensions)
        let entries = extensions.map { ext in
            SMBDirectoryEntry(name: "file.\(ext)", isDirectory: false, size: 1, modifiedAt: nil)
        }
        let lister = FakeSMBLister(entries: entries)
        let source = SMBFileSource(lister: lister, host: "nas", share: "Media", root: "")
        let files = try await source.mediaFiles(in: "")
        #expect(files.count == extensions.count)
        // Lock in the widened legacy set (RealMedia + the other libVLC-decodable containers).
        let widened: Set<String> = ["rmvb", "rm", "3gp", "mts", "vob", "divx", "asf", "m2v", "ogv", "ogm"]
        #expect(widened.isSubset(of: SMBFileSource.mediaExtensions))
    }

    @Test("SMBFileSource excludes a zero-byte media file (incomplete/stub)")
    func excludesZeroByteMedia() async throws {
        let lister = FakeSMBLister(entries: [
            .init(name: "Complete.mkv", isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "Stub.mkv",     isDirectory: false, size: 0, modifiedAt: nil),
        ])
        let source = SMBFileSource(lister: lister, host: "nas", share: "Media", root: "")
        let files = try await source.mediaFiles(in: "")
        #expect(files.map(\.name) == ["Complete.mkv"])
    }

    @Test("SMBFileSource extension check is case-insensitive")
    func extensionCaseInsensitive() async throws {
        let lister = FakeSMBLister(entries: [
            .init(name: "Movie.MKV", isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "Film.MP4",  isDirectory: false, size: 1, modifiedAt: nil),
        ])
        let source = SMBFileSource(lister: lister, host: "nas", share: "Media", root: "")
        let files = try await source.mediaFiles(in: "")
        #expect(files.count == 2)
    }

    // MARK: - No recursion

    @Test("SMBFileSource does not recurse into subdirectories")
    func noRecursion() async throws {
        // The fake always returns the same flat list — even directories are not followed.
        // The source must never call list() more than once (no recursive descent).
        var listCallCount = 0
        final class CountingLister: SMBLister, @unchecked Sendable {
            var count = 0
            let inner: FakeSMBLister
            init(inner: FakeSMBLister) { self.inner = inner }
            func listShares() async throws -> [SMBShare] { try await inner.listShares() }
            func list(share: String, path: String) async throws -> [SMBDirectoryEntry] {
                count += 1
                return try await inner.list(share: share, path: path)
            }
            func disconnect() async { await inner.disconnect() }
        }

        let base = FakeSMBLister(entries: [
            .init(name: "SubDir",  isDirectory: true,  size: 0, modifiedAt: nil),
            .init(name: "A.mkv",   isDirectory: false, size: 1, modifiedAt: nil),
        ])
        let counter = CountingLister(inner: base)
        let source = SMBFileSource(lister: counter, host: "nas", share: "Media", root: "")
        _ = try await source.mediaFiles(in: "")
        listCallCount = counter.count
        #expect(listCallCount == 1, "mediaFiles(in:) must call list exactly once — no recursion")
    }

    // MARK: - playableURL

    @Test("playableURL builds smb://host/share/name for a top-level file")
    func playableURLTopLevel() {
        let entry = SMBDirectoryEntry(name: "Movie.mkv", isDirectory: false, size: 1, modifiedAt: nil)
        let source = SMBFileSource(lister: FakeSMBLister(entries: []), host: "192.168.1.10", share: "Media", root: "")
        let url = source.playableURL(for: entry, in: "")
        #expect(url?.absoluteString == "smb://192.168.1.10/Media/Movie.mkv")
    }

    @Test("playableURL does not embed credentials in the URL string")
    func playableURLNoCredentials() {
        let entry = SMBDirectoryEntry(name: "Film.mp4", isDirectory: false, size: 1, modifiedAt: nil)
        let source = SMBFileSource(lister: FakeSMBLister(entries: []), host: "nas-host", share: "Videos", root: "")
        let url = source.playableURL(for: entry, in: "")
        let raw = url?.absoluteString ?? ""
        #expect(!raw.contains("@"), "URL must not contain credential separator '@'")
        #expect(!raw.contains("password"), "URL must not contain any password token")
    }

    @Test("playableURL percent-encodes '#' and '?' so the filename isn't truncated")
    func playableURLEncodesStructuralDelimiters() {
        let source = SMBFileSource(lister: FakeSMBLister(entries: []), host: "nas", share: "Media", root: "Movies")

        let hashEntry = SMBDirectoryEntry(name: "Episode#1.mkv", isDirectory: false, size: 1, modifiedAt: nil)
        let hashURL = source.playableURL(for: hashEntry, in: "")
        // '#' must be encoded, NOT parsed as a fragment that truncates the path.
        #expect(hashURL?.fragment == nil)
        #expect(hashURL?.absoluteString.contains("%23") == true)
        // libVLC decodes %23 back to '#', so the last path component is the real filename.
        #expect(hashURL?.lastPathComponent == "Episode#1.mkv")

        let queryEntry = SMBDirectoryEntry(name: "Show?.mkv", isDirectory: false, size: 1, modifiedAt: nil)
        let queryURL = source.playableURL(for: queryEntry, in: "")
        #expect(queryURL?.query == nil)
        #expect(queryURL?.lastPathComponent == "Show?.mkv")
    }

    // MARK: - disconnect

    @Test("disconnect forwards to the underlying lister")
    func disconnectForwards() async {
        let lister = FakeSMBLister(entries: [])
        let source = SMBFileSource(lister: lister, host: "nas", share: "Media", root: "")
        await source.disconnect()
        #expect(lister.disconnectCalled)
    }

    // MARK: - listShares

    @Test("FakeSMBLister.listShares returns the canned shares")
    func listSharesReturnsCanned() async throws {
        let lister = FakeSMBLister(entries: [], shares: [
            SMBShare(name: "Media", comment: "Movies & TV"),
            SMBShare(name: "Backups", comment: ""),
        ])
        let shares = try await lister.listShares()
        #expect(shares.map(\.name) == ["Media", "Backups"])
    }

    // MARK: - ItemID codec

    @Test("decodeItemID round-trips itemID(share:path:)")
    func itemIDRoundTrips() {
        let id = SMBFileSource.itemID(share: "Media", path: "Movies/Film.mkv")
        let decoded = SMBFileSource.decodeItemID(id)
        #expect(decoded?.share == "Media")
        #expect(decoded?.path == "Movies/Film.mkv")
    }

    @Test("decodeItemID returns nil for an id with no share prefix")
    func decodeItemIDNoColon() {
        #expect(SMBFileSource.decodeItemID(ItemID(rawValue: "nocolon")) == nil)
    }

    @Test("item(from:in:) encodes the full share-relative path in the ItemID")
    func itemEncodesPath() {
        let entry = SMBDirectoryEntry(name: "Film.mkv", isDirectory: false, size: 10, modifiedAt: nil)
        let item = SMBFileSource.item(from: entry, share: "Media", in: "Movies")
        #expect(item.id == ItemID(rawValue: "Media:Movies/Film.mkv"))
        if case .movie(let m) = item {
            #expect(m.title == "Film")   // name minus extension
            #expect(m.size == 10)        // entry.size carried through
        } else { Issue.record("expected .movie") }
    }

    @Test("item(from:in:) at root (empty dirPath) encodes name without a leading slash")
    func itemEncodesPathAtRoot() {
        let entry = SMBDirectoryEntry(name: "Film.mkv", isDirectory: false, size: 10, modifiedAt: nil)
        let item = SMBFileSource.item(from: entry, share: "Media", in: "")
        #expect(item.id == ItemID(rawValue: "Media:Film.mkv"))
    }

    @Test("decodeItemID returns nil for a trailing-colon id (empty path)")
    func decodeItemIDEmptyPath() {
        #expect(SMBFileSource.decodeItemID(ItemID(rawValue: "Media:")) == nil)
    }

    // MARK: - browse

    @Test("browse partitions into name-sorted folders and media, excluding non-media and zero-byte")
    func browsePartitions() async throws {
        let lister = FakeSMBLister(entries: [
            SMBDirectoryEntry(name: "TV", isDirectory: true, size: 0, modifiedAt: nil),
            SMBDirectoryEntry(name: "Movies", isDirectory: true, size: 0, modifiedAt: nil),
            SMBDirectoryEntry(name: "B.mkv", isDirectory: false, size: 5, modifiedAt: nil),
            SMBDirectoryEntry(name: "A.mp4", isDirectory: false, size: 5, modifiedAt: nil),
            SMBDirectoryEntry(name: "readme.txt", isDirectory: false, size: 5, modifiedAt: nil),
            SMBDirectoryEntry(name: "stub.mkv", isDirectory: false, size: 0, modifiedAt: nil),
        ])
        let source = SMBFileSource(lister: lister, host: "nas", share: "Media", root: "")
        let listing = try await source.browse(in: "")

        #expect(listing.folders.map(\.name) == ["Movies", "TV"])      // name-sorted dirs
        #expect(listing.media.count == 2)                              // txt + zero-byte excluded
        #expect(listing.media.first?.id == ItemID(rawValue: "Media:A.mp4")) // name-sorted, path-encoded
    }
}
