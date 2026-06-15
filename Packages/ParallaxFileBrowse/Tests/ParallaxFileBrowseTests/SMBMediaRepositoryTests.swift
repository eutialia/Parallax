import Foundation
import Testing
import ParallaxCore
@testable import ParallaxFileBrowse

@Suite("SMBMediaRepository")
struct SMBMediaRepositoryTests {

    // MARK: - Helpers

    private func makeRepo(
        share: String = "Media",
        roots: [String] = ["Movies"],
        entries: [SMBDirectoryEntry] = []
    ) -> SMBMediaRepository {
        let lister = FakeSMBLister(entries: entries)
        return SMBMediaRepository(lister: lister, share: share, roots: roots)
    }

    /// A lister whose `list` always throws the supplied error — exercises the
    /// repository's raw-error → `AppError` mapping (so a failure reaches the UI as a
    /// meaningful message, not a bare "Something went wrong.").
    private final class ThrowingSMBLister: SMBLister, @unchecked Sendable {
        let error: Error
        init(error: Error) { self.error = error }
        func list(share: String, path: String) async throws -> [SMBDirectoryEntry] { throw error }
        func disconnect() async {}
    }

    private func makeThrowingRepo(_ error: Error, share: String = "Media", root: String = "Movies") -> SMBMediaRepository {
        SMBMediaRepository(lister: ThrowingSMBLister(error: error), share: share, roots: [root])
    }

    // MARK: - collections()

    @Test("collections() returns one MediaCollection per root")
    func collectionsCountMatchesRoots() async throws {
        let repo = makeRepo(share: "Media", roots: ["Movies", "TV", "Kids"])
        let cols = try await repo.collections()
        #expect(cols.count == 3)
    }

    @Test("collections() gives each collection a stable ID derived from share+root")
    func collectionsHaveStableIDs() async throws {
        let repo = makeRepo(share: "Media", roots: ["Movies"])
        let colsA = try await repo.collections()
        let colsB = try await repo.collections()
        #expect(colsA[0].id == colsB[0].id)
        // The raw value encodes both share and root
        #expect(colsA[0].id.rawValue.contains("Media"))
        #expect(colsA[0].id.rawValue.contains("Movies"))
    }

    @Test("collections() IDs are unique across different roots")
    func collectionsIDsAreUniquePerRoot() async throws {
        let repo = makeRepo(share: "Media", roots: ["Movies", "TV"])
        let cols = try await repo.collections()
        let ids = cols.map(\.id)
        #expect(Set(ids).count == ids.count, "Each root must produce a distinct CollectionID")
    }

    @Test("collections() name is last path component of root")
    func collectionsNameIsLastPathComponent() async throws {
        let repo = makeRepo(share: "Media", roots: ["Films/Action", "TV"])
        let cols = try await repo.collections()
        let names = cols.map(\.name)
        #expect(names.contains("Action"))
        #expect(names.contains("TV"))
    }

    @Test("collections() for a root of empty string uses the share name")
    func collectionsEmptyRootUsesShareName() async throws {
        let repo = makeRepo(share: "NAS", roots: [""])
        let cols = try await repo.collections()
        #expect(cols[0].name == "NAS")
    }

    @Test("collections() collectionType is .movies")
    func collectionsTypeIsMovies() async throws {
        let repo = makeRepo(share: "Media", roots: ["Movies"])
        let cols = try await repo.collections()
        #expect(cols[0].collectionType == .movies)
    }

    @Test("collections() primaryTag is nil (no artwork for SMB folders)")
    func collectionsPrimaryTagIsNil() async throws {
        let repo = makeRepo(share: "Media", roots: ["Movies"])
        let cols = try await repo.collections()
        #expect(cols[0].primaryTag == nil)
    }

    // MARK: - items(in:filter:sort:cursor:)

    @Test("items() maps top-level media files to Movie-like Items")
    func itemsMapsMediaFilesToItems() async throws {
        let entries: [SMBDirectoryEntry] = [
            .init(name: "Inception.mkv", isDirectory: false, size: 1_000_000, modifiedAt: nil),
            .init(name: "Dune.mp4",      isDirectory: false, size: 2_000_000, modifiedAt: nil),
        ]
        let repo = makeRepo(share: "Media", roots: ["Movies"], entries: entries)
        let cols = try await repo.collections()
        let page = try await repo.items(in: .collection(cols[0].id), filter: .init(), sort: .defaultForLibrary, cursor: nil)
        #expect(page.items.count == 2)
        let titles = page.items.map(\.displayTitle).sorted()
        #expect(titles == ["Dune", "Inception"])
    }

    @Test("items() strips the file extension from the title")
    func itemsStripsExtension() async throws {
        let entries: [SMBDirectoryEntry] = [
            .init(name: "My.Movie.2024.mkv", isDirectory: false, size: 1, modifiedAt: nil),
        ]
        let repo = makeRepo(share: "Media", roots: ["Movies"], entries: entries)
        let cols = try await repo.collections()
        let page = try await repo.items(in: .collection(cols[0].id), filter: .init(), sort: .defaultForLibrary, cursor: nil)
        #expect(page.items[0].displayTitle == "My.Movie.2024")
    }

    @Test("items() excludes directories")
    func itemsExcludesDirectories() async throws {
        let entries: [SMBDirectoryEntry] = [
            .init(name: "Season 1", isDirectory: true,  size: 0, modifiedAt: nil),
            .init(name: "Film.mkv", isDirectory: false, size: 1, modifiedAt: nil),
        ]
        let repo = makeRepo(share: "Media", roots: ["Movies"], entries: entries)
        let cols = try await repo.collections()
        let page = try await repo.items(in: .collection(cols[0].id), filter: .init(), sort: .defaultForLibrary, cursor: nil)
        #expect(page.items.count == 1)
        #expect(page.items[0].displayTitle == "Film")
    }

    @Test("items() excludes non-media files")
    func itemsExcludesNonMedia() async throws {
        let entries: [SMBDirectoryEntry] = [
            .init(name: "poster.jpg",  isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "readme.txt",  isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "Movie.mkv",   isDirectory: false, size: 1, modifiedAt: nil),
        ]
        let repo = makeRepo(share: "Media", roots: ["Movies"], entries: entries)
        let cols = try await repo.collections()
        let page = try await repo.items(in: .collection(cols[0].id), filter: .init(), sort: .defaultForLibrary, cursor: nil)
        #expect(page.items.count == 1)
    }

    @Test("items() produces stable ItemIDs derived from the file path")
    func itemsHaveStableIDs() async throws {
        let entries: [SMBDirectoryEntry] = [
            .init(name: "Film.mkv", isDirectory: false, size: 1, modifiedAt: nil),
        ]
        let repo = makeRepo(share: "Media", roots: ["Movies"], entries: entries)
        let cols = try await repo.collections()
        let scope = LibraryScope.collection(cols[0].id)
        let pageA = try await repo.items(in: scope, filter: .init(), sort: .defaultForLibrary, cursor: nil)
        let pageB = try await repo.items(in: scope, filter: .init(), sort: .defaultForLibrary, cursor: nil)
        #expect(pageA.items[0].id == pageB.items[0].id)
    }

    @Test("items() two different files get different ItemIDs")
    func itemsDistinctFilesGetDistinctIDs() async throws {
        let entries: [SMBDirectoryEntry] = [
            .init(name: "A.mkv", isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "B.mkv", isDirectory: false, size: 1, modifiedAt: nil),
        ]
        let repo = makeRepo(share: "Media", roots: ["Movies"], entries: entries)
        let cols = try await repo.collections()
        let page = try await repo.items(in: .collection(cols[0].id), filter: .init(), sort: .defaultForLibrary, cursor: nil)
        let ids = page.items.map(\.id)
        #expect(Set(ids).count == ids.count, "Each file must yield a unique ItemID")
    }

    @Test("items() returns a single page with nil nextCursor")
    func itemsReturnsSinglePage() async throws {
        let entries: [SMBDirectoryEntry] = (1...5).map { i in
            .init(name: "Movie\(i).mkv", isDirectory: false, size: 1, modifiedAt: nil)
        }
        let repo = makeRepo(share: "Media", roots: ["Movies"], entries: entries)
        let cols = try await repo.collections()
        let page = try await repo.items(in: .collection(cols[0].id), filter: .init(), sort: .defaultForLibrary, cursor: nil)
        #expect(page.nextCursor == nil)
        #expect(page.total == 5)
    }

    @Test("items() total equals items count (no server-side total)")
    func itemsTotalEqualsCount() async throws {
        let entries: [SMBDirectoryEntry] = [
            .init(name: "A.mkv", isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "B.mkv", isDirectory: false, size: 1, modifiedAt: nil),
            .init(name: "C.mkv", isDirectory: false, size: 1, modifiedAt: nil),
        ]
        let repo = makeRepo(share: "Media", roots: ["Movies"], entries: entries)
        let cols = try await repo.collections()
        let page = try await repo.items(in: .collection(cols[0].id), filter: .init(), sort: .defaultForLibrary, cursor: nil)
        #expect(page.total == page.items.count)
    }

    @Test("items() with .favorites scope returns empty page")
    func itemsFavoritesScopeReturnsEmpty() async throws {
        let entries: [SMBDirectoryEntry] = [
            .init(name: "Film.mkv", isDirectory: false, size: 1, modifiedAt: nil),
        ]
        let repo = makeRepo(share: "Media", roots: ["Movies"], entries: entries)
        let page = try await repo.items(in: .favorites, filter: .init(), sort: .defaultForLibrary, cursor: nil)
        #expect(page.items.isEmpty)
        #expect(page.nextCursor == nil)
    }

    @Test("items() modeled as .movie case")
    func itemsAreMovieCase() async throws {
        let entries: [SMBDirectoryEntry] = [
            .init(name: "Film.mkv", isDirectory: false, size: 1, modifiedAt: nil),
        ]
        let repo = makeRepo(share: "Media", roots: ["Movies"], entries: entries)
        let cols = try await repo.collections()
        let page = try await repo.items(in: .collection(cols[0].id), filter: .init(), sort: .defaultForLibrary, cursor: nil)
        if case .movie = page.items[0] {
            // correct
        } else {
            Issue.record("Expected .movie case, got \(page.items[0])")
        }
    }

    // MARK: - items() error mapping

    @Test("items() maps a POSIX permission failure to AppError.source(.permissionDenied)")
    func itemsMapsPermissionError() async throws {
        let denied = NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EACCES.rawValue))
        let repo = makeThrowingRepo(denied)
        let cols = try await repo.collections()
        do {
            _ = try await repo.items(in: .collection(cols[0].id), filter: .init(), sort: .defaultForLibrary, cursor: nil)
            Issue.record("expected items() to throw when the lister fails")
        } catch AppError.source(.permissionDenied) {
            // expected — a bare NSError would otherwise reach the UI as "Something went wrong."
        } catch {
            Issue.record("expected AppError.source(.permissionDenied), got \(error)")
        }
    }

    @Test("items() maps a non-POSIX list failure to AppError.source(.connectionLost)")
    func itemsMapsGenericErrorToConnectionLost() async throws {
        let generic = NSError(domain: "SMB2", code: 5)
        let repo = makeThrowingRepo(generic)
        let cols = try await repo.collections()
        do {
            _ = try await repo.items(in: .collection(cols[0].id), filter: .init(), sort: .defaultForLibrary, cursor: nil)
            Issue.record("expected items() to throw when the lister fails")
        } catch AppError.source(.connectionLost) {
            // expected
        } catch {
            Issue.record("expected AppError.source(.connectionLost), got \(error)")
        }
    }

    // MARK: - playablePath(fromItemID:share:)

    @Test("playablePath recovers the share-relative path that item(from:) encoded")
    func playablePathRoundTrips() async throws {
        let entries: [SMBDirectoryEntry] = [
            .init(name: "Film.mkv", isDirectory: false, size: 1, modifiedAt: nil),
        ]
        let repo = makeRepo(share: "Media", roots: ["Movies"], entries: entries)
        let cols = try await repo.collections()
        let page = try await repo.items(in: .collection(cols[0].id), filter: .init(), sort: .defaultForLibrary, cursor: nil)
        let item = try #require(page.items.first)

        // Decode should return the encoded path "Movies/Film.mkv"
        let decoded = SMBMediaRepository.playablePath(fromItemID: item.id, share: "Media")
        #expect(decoded == "Movies/Film.mkv")
    }

    @Test("playablePath returns nil for a foreign ItemID (wrong share prefix)")
    func playablePathForeignIDReturnsNil() {
        let foreignID = ItemID(rawValue: "OtherShare:Movies/Film.mkv")
        let decoded = SMBMediaRepository.playablePath(fromItemID: foreignID, share: "Media")
        #expect(decoded == nil)
    }

    // MARK: - genres(in:)

    @Test("genres() always returns empty array")
    func genresAlwaysEmpty() async throws {
        let repo = makeRepo(share: "Media", roots: ["Movies"])
        let genres = try await repo.genres(in: .collection(CollectionID(rawValue: "Media:Movies")))
        #expect(genres.isEmpty)
    }

    @Test("genres() returns empty for favorites scope")
    func genresFavoritesEmpty() async throws {
        let repo = makeRepo(share: "Media", roots: ["Movies"])
        let genres = try await repo.genres(in: .favorites)
        #expect(genres.isEmpty)
    }
}
