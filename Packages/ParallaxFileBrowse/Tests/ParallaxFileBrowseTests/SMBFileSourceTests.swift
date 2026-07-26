import Foundation
import Testing
import ParallaxCore
@testable import ParallaxFileBrowse

@Suite("SMBFileSource")
struct SMBFileSourceTests {

    // MARK: - Media filter

    struct FilterCase: Sendable, CustomTestStringConvertible {
        let name: String
        let entries: [SMBDirectoryEntry]
        let expected: [String]
        var testDescription: String { name }
    }

    static let filterCases: [FilterCase] = [
        .init(name: "non-media siblings and folders excluded",
              entries: [SMBEntry.file("A.mkv"), SMBEntry.file("B.mp4"), SMBEntry.file("poster.jpg"),
                        SMBEntry.file("readme.txt"), SMBEntry.dir("Season 1")],
              expected: ["A.mkv", "B.mp4"]),
        .init(name: "a directory with a media extension is still a directory",
              entries: [SMBEntry.dir("FakeDir.mkv"), SMBEntry.file("Real.m4v")],
              expected: ["Real.m4v"]),
        .init(name: "zero-byte media (an interrupted download's stub) is dropped",
              entries: [SMBEntry.file("Complete.mkv"), SMBEntry.file("Stub.mkv", size: 0)],
              expected: ["Complete.mkv"]),
        .init(name: "extension matching is case-insensitive",
              entries: [SMBEntry.file("Movie.MKV"), SMBEntry.file("Film.Mp4")],
              expected: ["Movie.MKV", "Film.Mp4"]),
        .init(name: "temp-suffix partials never reach the grid",
              entries: [SMBEntry.file("Film.mkv.part"), SMBEntry.file("Film.mkv.crdownload"),
                        SMBEntry.file("Film.mkv.!qB"), SMBEntry.file("Film.mkv")],
              expected: ["Film.mkv"]),
        .init(name: "an extensionless file is not media",
              entries: [SMBEntry.file("README"), SMBEntry.file("Film.avi")],
              expected: ["Film.avi"]),
    ]

    @Test("mediaFiles keeps only playable media", arguments: filterCases)
    func mediaFilesFilter(_ testCase: FilterCase) async throws {
        let files = try await makeFileSource(testCase.entries).mediaFiles(in: "")
        #expect(files.map(\.name) == testCase.expected)
    }

    @Test("every extension in the allowlist is accepted")
    func recognisesAllMediaExtensions() async throws {
        // Driven from the production allowlist so widening the set can't leave this stale.
        let extensions = SMBFileSource.mediaExtensions.sorted()
        let entries = extensions.map { SMBEntry.file("file.\($0)") }
        let files = try await makeFileSource(entries).mediaFiles(in: "")
        #expect(files.map(\.name) == entries.map(\.name))
    }

    @Test("mediaFiles calls list exactly once — no recursive descent")
    func noRecursion() async throws {
        // The fake returns the same entries at every level, so only the call count can tell a
        // single listing apart from a walk.
        let lister = CountingSMBLister(FakeSMBLister(entries: [SMBEntry.dir("SubDir"), SMBEntry.file("A.mkv")]))
        let source = SMBFileSource(lister: lister, host: "nas", share: "Media", root: "")

        _ = try await source.mediaFiles(in: "")

        #expect(lister.listCallCount == 1)
    }

    @Test("an empty path lists the configured root; a non-empty path replaces it")
    func pathReplacesRootRatherThanJoining() async throws {
        let lister = RecordingPathLister()
        let source = SMBFileSource(lister: lister, host: "nas", share: "Media", root: "Movies")

        _ = try await source.mediaFiles(in: "")
        _ = try await source.mediaFiles(in: "TV/Show")

        #expect(lister.listedPaths == ["Movies", "TV/Show"])
    }

    // MARK: - playableURL

    @Test("playableURL builds a credential-free smb://host/share/path")
    func playableURLShape() {
        let source = makeFileSource([], host: "192.168.1.10", share: "Media", root: "Movies")
        let url = source.playableURL(for: SMBEntry.file("Movie.mkv"), in: "")
        #expect(url.absoluteString == "smb://192.168.1.10/Media/Movies/Movie.mkv")
    }

    @Test("playableURL prefers the browsed path over the configured root")
    func playableURLUsesTheBrowsedPath() {
        let source = makeFileSource([], root: "Movies")
        let url = source.playableURL(for: SMBEntry.file("Ep.mkv"), in: "TV/Show/Season 1")
        #expect(url.absoluteString == "smb://nas/Media/TV/Show/Season%201/Ep.mkv")
    }

    @Test("playableURL percent-encodes '#' and '?' so the filename isn't truncated",
          arguments: [("Episode#1.mkv", "%23"), ("Show?.mkv", "%3F")])
    func playableURLEncodesStructuralDelimiters(_ name: String, _ encoding: String) {
        let source = makeFileSource([], root: "Movies")
        let url = source.playableURL(for: SMBEntry.file(name), in: "")

        #expect(url.absoluteString.contains(encoding))
        #expect(url.fragment == nil, "'#' must not be parsed as a fragment")
        #expect(url.query == nil, "'?' must not be parsed as a query")
        // libVLC decodes the escape back, so the last component is the real filename.
        #expect(url.lastPathComponent == name)
    }

    // MARK: - disconnect

    @Test("disconnect forwards to the underlying lister")
    func disconnectForwards() async {
        let lister = FakeSMBLister(entries: [])
        await SMBFileSource(lister: lister, host: "nas", share: "Media", root: "").disconnect()
        #expect(lister.disconnectCalled)
    }

    // MARK: - ItemID codec

    @Test("decodeItemID round-trips itemID(share:path:)",
          arguments: ["Movies/Film.mkv", "Film.mkv", "A/B/C/Deep Film.mkv", "Show?/Ep#1.mkv"])
    func itemIDRoundTrips(_ path: String) throws {
        let decoded = try #require(SMBFileSource.decodeItemID(SMBFileSource.itemID(share: "Media", path: path)))
        #expect(decoded.share == "Media")
        #expect(decoded.path == path)
    }

    /// None of these is playable: there is no share to anchor an `smb://` URL on, or no file to open.
    @Test("decodeItemID rejects ids that can't address a file",
          arguments: ["nocolon", "Media:", ":Movies/Film.mkv", ":"])
    func decodeItemIDRejectsUnaddressable(_ raw: String) {
        #expect(SMBFileSource.decodeItemID(ItemID(rawValue: raw)) == nil)
    }

    @Test("item(from:in:) encodes the share-relative path, title and size",
          arguments: [("Movies", "Media:Movies/Film.mkv"), ("", "Media:Film.mkv")])
    func itemEncodesPath(_ dirPath: String, _ expectedID: String) throws {
        let item = SMBFileSource.item(from: SMBEntry.file("Film.mkv", size: 10), share: "Media", in: dirPath)

        #expect(item.id == ItemID(rawValue: expectedID))
        guard case .movie(let movie) = item else {
            Issue.record("expected .movie")
            return
        }
        #expect(movie.title == "Film", "the title is the name minus its extension")
        #expect(movie.size == 10)
    }

    @Test("withUserData preserves Movie.size — the SMB thumbnail cache key depends on it")
    func withUserDataPreservesSize() throws {
        // Toggling favorite/played rebuilds the Movie; if size isn't echoed, the thumbnail cache key
        // (serverID+share+path+size+mtime) shifts and every frame-grab regenerates after a user-data
        // change. Guards the Item.withUserData invariant the SMB grid leans on.
        let item = SMBFileSource.item(from: SMBEntry.file("Film.mkv", size: 1_234_567), share: "Media", in: "")
        let toggled = item.withFavorite(true)

        guard case .movie(let rebuilt) = toggled else {
            Issue.record("expected .movie")
            return
        }
        #expect(rebuilt.size == 1_234_567, "withUserData must echo Movie.size (cache-key stability)")
        #expect(rebuilt.userData.isFavorite, "the favorite toggle must take effect")
    }

    // MARK: - Error mapping

    /// How the failure reaches the mapper. AMSMB2 usually surfaces the `NSPOSIXErrorDomain` bridge,
    /// but a thrown Swift `POSIXError` value has to classify identically.
    enum ErrorShape: Sendable {
        case bridgedPOSIX(POSIXErrorCode)
        case posixValue(POSIXErrorCode)
        case foreignDomain

        var error: any Error {
            switch self {
            case .bridgedPOSIX(let code): NSError(domain: NSPOSIXErrorDomain, code: Int(code.rawValue))
            case .posixValue(let code): POSIXError(code)
            case .foreignDomain: NSError(domain: "SomeOtherDomain", code: 42)
            }
        }
    }

    /// A comparable projection of the classifications this mapper can produce. `AppError` is not
    /// Equatable (some cases carry non-Equatable payloads), so the table compares tags rather than
    /// repeating `guard case` boilerplate per errno.
    enum Classification: Sendable, Equatable {
        case invalidCredentials
        case permissionDenied
        case notFound
        case connectionLost
        case other(String)

        init(_ error: AppError) {
            switch error {
            case .auth(.invalidCredentials): self = .invalidCredentials
            case .source(.permissionDenied): self = .permissionDenied
            case .source(.notFound): self = .notFound
            case .source(.connectionLost): self = .connectionLost
            default: self = .other(String(describing: error))
            }
        }
    }

    struct ErrorCase: Sendable, CustomTestStringConvertible {
        let name: String
        let shape: ErrorShape
        let expected: Classification
        var testDescription: String { name }
    }

    /// EPERM is deliberately NOT bucketed with EACCES: libsmb2's only EPERM source is its
    /// NT-status→errno table, so the TCP connect succeeded and the SERVER refused the sign-in (the
    /// fix is re-entering credentials). A genuine share ACL denial arrives as EACCES instead.
    static let errorCases: [ErrorCase] = [
        .init(name: "EPERM → invalid credentials", shape: .bridgedPOSIX(.EPERM), expected: .invalidCredentials),
        .init(name: "EACCES → permission denied", shape: .bridgedPOSIX(.EACCES), expected: .permissionDenied),
        .init(name: "ENOENT → not found", shape: .bridgedPOSIX(.ENOENT), expected: .notFound),
        .init(name: "ENOTDIR → not found", shape: .bridgedPOSIX(.ENOTDIR), expected: .notFound),
        .init(name: "ENODEV → not found", shape: .bridgedPOSIX(.ENODEV), expected: .notFound),
        .init(name: "ETIMEDOUT → connection lost", shape: .bridgedPOSIX(.ETIMEDOUT), expected: .connectionLost),
        .init(name: "non-POSIX domain → connection lost", shape: .foreignDomain, expected: .connectionLost),
        .init(name: "thrown POSIXError value → permission denied",
              shape: .posixValue(.EACCES), expected: .permissionDenied),
    ]

    @Test("mapListError classifies the failure", arguments: errorCases)
    func mapListErrorClassifies(_ testCase: ErrorCase) {
        let classified = Classification(SMBFileSource.mapListError(testCase.shape.error, share: "Media", path: "x"))
        #expect(classified == testCase.expected)
    }

    @Test("mapShareListError classifies identically — only the log context differs", arguments: errorCases)
    func mapShareListErrorClassifies(_ testCase: ErrorCase) {
        let classified = Classification(SMBFileSource.mapShareListError(testCase.shape.error, host: "nas"))
        #expect(classified == testCase.expected)
    }

    // MARK: - browse

    @Test("browse partitions into folders and media, excluding non-media and zero-byte files")
    func browsePartitions() async throws {
        let source = makeFileSource([
            SMBEntry.dir("TV"), SMBEntry.dir("Movies"),
            SMBEntry.file("B.mkv", size: 5), SMBEntry.file("A.mp4", size: 5),
            SMBEntry.file("readme.txt"), SMBEntry.file("stub.mkv", size: 0),
        ])

        let listing = try await source.browse(in: "", sort: .init(field: .name, direction: .ascending))

        #expect(listing.folders.map(\.name) == ["Movies", "TV"])
        #expect(listing.media.map(\.id) == [ItemID(rawValue: "Media:A.mp4"), ItemID(rawValue: "Media:B.mkv")])
    }

    /// Folders live in their own array precisely so the grid can render them above media whatever
    /// the sort says — a newer file must never leapfrog an older folder.
    @Test("a media file newer than a folder still sorts below it")
    func browseKeepsFoldersAboveMedia() async throws {
        let source = makeFileSource([
            SMBEntry.dir("Old Folder", modified: Date(timeIntervalSince1970: 1)),
            SMBEntry.file("brand-new.mkv", size: 5, modified: Date(timeIntervalSince1970: 9_999)),
        ])

        let listing = try await source.browse(in: "", sort: .init(field: .dateModified, direction: .descending))

        #expect(listing.folders.map(\.name) == ["Old Folder"])
        #expect(listing.media.map(\.displayTitle) == ["brand-new"])
    }

    /// browse applies the requested sort to BOTH groups. The per-field comparator semantics are
    /// pinned in `SMBBrowseSortTests`; this is the wiring.
    @Test("browse applies the sort to folders and media alike",
          arguments: [(SMBBrowseSort(field: .name, direction: .ascending), ["Alpha", "Zelda"], ["a", "z"]),
                      (SMBBrowseSort(field: .name, direction: .descending), ["Zelda", "Alpha"], ["z", "a"])])
    func browseAppliesTheSortToBothGroups(
        _ sort: SMBBrowseSort,
        _ expectedFolders: [String],
        _ expectedMedia: [String]
    ) async throws {
        let source = makeFileSource([
            SMBEntry.dir("Zelda"), SMBEntry.dir("Alpha"),
            SMBEntry.file("z.mkv", size: 5), SMBEntry.file("a.mkv", size: 5),
        ])

        let listing = try await source.browse(in: "", sort: sort)

        #expect(listing.folders.map(\.name) == expectedFolders)
        #expect(listing.media.map(\.displayTitle) == expectedMedia)
    }

    @Test("browse defaults to newest-created first, falling back to name A→Z with no btime")
    func browseDefaultsToNewestCreated() async throws {
        let dated = makeFileSource([
            SMBEntry.dir("Old", created: Date(timeIntervalSince1970: 100)),
            SMBEntry.dir("New", created: Date(timeIntervalSince1970: 900)),
            SMBEntry.file("old.mkv", size: 5, created: Date(timeIntervalSince1970: 100)),
            SMBEntry.file("new.mkv", size: 5, created: Date(timeIntervalSince1970: 900)),
        ])
        let datedListing = try await dated.browse(in: "")
        #expect(datedListing.folders.map(\.name) == ["New", "Old"])
        #expect(datedListing.media.map(\.displayTitle) == ["new", "old"])

        // A server that omits btime degrades to name A→Z, never to a random order.
        let undated = makeFileSource([
            SMBEntry.dir("Zelda"), SMBEntry.dir("Alpha"),
            SMBEntry.file("z.mkv", size: 5), SMBEntry.file("a.mkv", size: 5),
        ])
        let undatedListing = try await undated.browse(in: "")
        #expect(undatedListing.folders.map(\.name) == ["Alpha", "Zelda"])
        #expect(undatedListing.media.map(\.displayTitle) == ["a", "z"])
    }

    @Test("browse strictly matches sidecar artwork per media item, ignoring folder art")
    func browseMatchesSidecarArtwork() async throws {
        let source = makeFileSource([
            SMBEntry.file("Film.mkv", size: 5),
            SMBEntry.file("Film-thumb.jpg", size: 900),
            SMBEntry.file("Other.mkv", size: 5),
            SMBEntry.file("Other.png", size: 800),
            SMBEntry.file("Lonely.mkv", size: 5),
            // Folder-level art with no same-stemmed video: must NOT attach to any tile.
            SMBEntry.file("folder.jpg", size: 700),
        ])

        let listing = try await source.browse(in: "Movies")

        // Film → its explicit -thumb; Other → its bare same-stem png; Lonely → no sidecar (falls
        // through to a frame-grab); folder.jpg is attached to nobody.
        #expect(listing.artwork[ItemID(rawValue: "Media:Movies/Film.mkv")]?.name == "Film-thumb.jpg")
        #expect(listing.artwork[ItemID(rawValue: "Media:Movies/Other.mkv")]?.name == "Other.png")
        #expect(listing.artwork[ItemID(rawValue: "Media:Movies/Lonely.mkv")] == nil)
        #expect(listing.artwork.count == 2, "only the two strictly-matched items carry artwork")
        // The matched entry carries the IMAGE's size — the provider gates thumbnail work on it.
        #expect(listing.artwork[ItemID(rawValue: "Media:Movies/Film.mkv")]?.size == 900)
    }

    @Test("browse skips sidecar matching entirely when the listing holds no images")
    func browseWithoutImagesCarriesNoArtwork() async throws {
        let listing = try await makeFileSource([SMBEntry.file("Film.mkv", size: 5)]).browse(in: "")
        #expect(listing.artwork.isEmpty)
    }
}

/// Records the path each `list` call actually resolved to — the only way to observe root-vs-path
/// resolution, which produces identical entries either way.
private final class RecordingPathLister: SMBLister, @unchecked Sendable {
    private(set) var listedPaths: [String] = []

    func listShares() async throws -> [SMBShare] { [] }

    func list(share: String, path: String) async throws -> [SMBDirectoryEntry] {
        listedPaths.append(path)
        return []
    }

    func disconnect() async {}
}
