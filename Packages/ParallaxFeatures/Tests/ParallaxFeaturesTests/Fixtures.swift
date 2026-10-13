import Foundation
import ParallaxCore
import ParallaxCoreTestSupport
@testable import ParallaxFeatures
import ParallaxJellyfin
import ParallaxTestScaling
import Testing

// Package-side copies of the app test target's `SharedFixtures` builders these suites need. The
// app-hosted bundle cannot link a test-support product without duplicating the packages it hosts,
// so the two targets keep their own.

func makeSession(_ id: String, name: String? = nil) -> Session {
    Session(
        id: ServerID(rawValue: id),
        data: JellyfinServerData(
            serverURL: URL(string: "https://\(id).example.test")!,
            serverName: name ?? "Server \(id)",
            user: UserSnapshot(id: "user-\(id)", name: "User", serverLastUpdatedAt: nil)
        ),
        accessToken: "token-\(id)"
    )
}

/// `makeSession` wrapped as a `LibrarySource` — the shape the cross-server merge surfaces take.
func makeJellyfinSource(_ id: String, name: String? = nil) -> LibrarySource {
    .jellyfin(makeSession(id, name: name))
}

var testJellyfinSource: MediaSourceID { .jellyfin(ServerID(rawValue: "test-server")) }

/// A `Movie` with every field a suite might vary exposed and the rest left empty. `title`
/// defaults to the id, which is what the merge/ordering suites assert on.
func makeMovie(
    _ id: String,
    title: String? = nil,
    year: Int? = nil,
    runtime: Duration? = nil,
    played: Bool = false,
    positionTicks: Int64 = 0,
    playCount: Int = 0,
    isFavorite: Bool = false,
    lastPlayed: Date? = nil,
    dateAdded: Date? = nil
) -> Movie {
    Movie(
        id: ItemID(rawValue: id), title: title ?? id, overview: nil, year: year, runtime: runtime,
        communityRating: nil, officialRating: nil, genres: [],
        primaryTag: nil, backdropTags: [], logoTag: nil, thumbTag: nil,
        dateAdded: dateAdded,
        userData: UserItemData(
            played: played,
            playbackPositionTicks: positionTicks,
            playCount: playCount,
            isFavorite: isFavorite,
            lastPlayedDate: lastPlayed
        )
    )
}

/// `makeMovie` boxed as an `Item` — the form grids, pages and merges consume.
func makeMovieItem(
    _ id: String,
    title: String? = nil,
    played: Bool = false,
    positionTicks: Int64 = 0,
    playCount: Int = 0,
    isFavorite: Bool = false,
    lastPlayed: Date? = nil,
    dateAdded: Date? = nil
) -> Item {
    .movie(makeMovie(
        id, title: title, played: played, positionTicks: positionTicks, playCount: playCount,
        isFavorite: isFavorite, lastPlayed: lastPlayed, dateAdded: dateAdded
    ))
}

/// A `Series` with only the fields the aggregation suites read; `title` defaults to the id.
func makeSeries(
    _ id: String,
    title: String? = nil,
    isFavorite: Bool = false
) -> Series {
    Series(
        id: ItemID(rawValue: id), title: title ?? id, overview: nil, year: nil, status: nil,
        communityRating: nil, officialRating: nil, genres: [],
        primaryTag: nil, backdropTags: [], logoTag: nil, thumbTag: nil, bannerTag: nil,
        userData: UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: isFavorite)
    )
}

/// An `Episode` with only the fields the aggregation suites read; `name` defaults to the id.
/// `season`/`index`/`positionTicks` stay nil/zero for the suites that don't care — the play-CTA
/// suites vary them, because "Resume S3 E1" and the resume-vs-play decision are derived from
/// exactly those three fields.
func makeEpisode(
    _ id: String,
    name: String? = nil,
    seriesID: String = "series",
    season: Int? = nil,
    index: Int? = nil,
    played: Bool = false,
    positionTicks: Int64 = 0,
    isFavorite: Bool = false
) -> Episode {
    Episode(
        id: ItemID(rawValue: id), seriesID: ItemID(rawValue: seriesID),
        seasonID: ItemID(rawValue: "\(seriesID)-s1"), name: name ?? id,
        seriesName: nil, indexNumber: index, parentIndexNumber: season,
        overview: nil, runtime: nil, primaryTag: nil,
        userData: UserItemData(
            played: played,
            playbackPositionTicks: positionTicks,
            playCount: played ? 1 : 0,
            isFavorite: isFavorite
        )
    )
}

/// A single, complete page of `items` — no cursor, total matching the payload.
func makePage(_ items: [Item]) -> Page<Item> {
    Page(items: items, total: items.count, nextCursor: nil)
}

func makeCollection(
    _ id: String,
    _ name: String,
    type: CollectionType = .movies
) -> MediaCollection {
    MediaCollection(id: CollectionID(rawValue: id), name: name, collectionType: type, primaryTag: nil)
}

func makeSMBServerData(
    host: String = "nas.local",
    username: String = "alice",
    domain: String = "WORKGROUP",
    shares: [String] = ["Media"]
) -> SMBServerData {
    SMBServerData(host: host, username: username, domain: domain, shares: shares)
}

/// `data` under the id `ServerStore.addSMBServer` gives it.
func makeSMBRef(_ data: SMBServerData = makeSMBServerData()) -> SMBServerRef {
    SMBServerRef(id: ServerStore.smbServerID(host: data.host), data: data)
}

/// A `ServerStore` on its own `UserDefaults` suite and a fake Keychain.
func makeIsolatedServerStore(label: String) -> ServerStore {
    let suiteName = "\(label)-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return ServerStore(
        settings: SettingsStore(defaults: defaults),
        keychain: FakeKeychain(),
        snapshots: SnapshotStore(container: URL.temporaryDirectory.appending(
            path: "scratch-snapshots-\(UUID().uuidString)", directoryHint: .isDirectory
        ))
    )
}

enum SMBTestFixtures {
    /// Runs `body` against a resume store on its own `UserDefaults` suite, removing the domain
    /// afterwards however `body` exits. Pass `#function` for `suite`.
    static func withResumeStore<Result>(
        suite: String,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (SMBResumeStore) async throws -> Result
    ) async throws -> Result {
        // The UUID is what makes it safe: suites run in parallel, and a parameterized test's cases
        // all report the same `#function`.
        let suiteName = "SMBTestFixtures.\(suite).\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suiteName)
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        return try await body(SMBResumeStore(defaults: try #require(UserDefaults(suiteName: suiteName))))
    }

    /// A resume store on a throwaway suite, for subjects that need one but write nothing through it.
    static func inertResumeStore() -> SMBResumeStore {
        let suiteName = "SMBTestFixtures.inert-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return SMBResumeStore(defaults: defaults)
    }

    /// A thumbnail cache over a fresh temp directory, removed however `body` exits. The eviction
    /// knobs pass straight through — small values exercise the sweep without writing thousands of
    /// files.
    static func withThumbnailCache<Result>(
        sizeCapBytes: Int64? = nil,
        trimTargetBytes: Int64? = nil,
        sweepInterval: Int? = nil,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (SMBThumbnailCache, URL) async throws -> Result
    ) async throws -> Result {
        // Canonical: on macOS the temp directory sits under `/var`, which a directory listing
        // reports as `/private/var`, and the suites compare URLs from both.
        let temporary = FileManager.default.temporaryDirectory
        let canonical = try temporary.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
        let directory = URL(filePath: canonical ?? temporary.path(), directoryHint: .isDirectory)
            .appendingPathComponent("smb-thumb-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache: SMBThumbnailCache
        if let sizeCapBytes, let trimTargetBytes, let sweepInterval {
            cache = SMBThumbnailCache(
                directory: directory,
                sizeCapBytes: sizeCapBytes,
                trimTargetBytes: trimTargetBytes,
                sweepInterval: sweepInterval
            )
        } else {
            cache = SMBThumbnailCache(directory: directory)
        }
        return try await body(cache, directory)
    }

    /// An `SMBThumbnailKey` with every field defaulted to the value most tests used, so a test that
    /// varies ONE discriminator says so by passing that one argument.
    static func thumbnailKey(
        serverID: String = "smb-nas",
        share: String = "Media",
        path: String = "Movies/Film.mkv",
        size: Int64 = 1234,
        modifiedAt: Date? = Date(timeIntervalSince1970: 1_000)
    ) -> SMBThumbnailKey {
        SMBThumbnailKey(serverID: serverID, share: share, path: path, size: size, modifiedAt: modifiedAt)
    }
}

/// A `UserDataWriting` with canned, per-call results for each operation, independently — no gate.
final class StubUserDataWriter: UserDataWriting, @unchecked Sendable {
    var favoriteResult: Result<UserItemData, Error>
    var playedResult: Result<UserItemData, Error>

    init(
        favorite: Result<UserItemData, Error>,
        played: Result<UserItemData, Error> = .success(UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: false))
    ) {
        self.favoriteResult = favorite
        self.playedResult = played
    }

    func setFavorite(itemID: ItemID, isFavorite: Bool) async throws -> UserItemData { try favoriteResult.get() }
    func setPlayed(itemID: ItemID, isPlayed: Bool) async throws -> UserItemData { try playedResult.get() }
}

/// Bounded yield loop for a test waiting on an async subscription (a `UserDataActions.changes()`
/// broadcast): hands control to the subscriber's `for await` Task until it has processed the value,
/// without a wall-clock sleep. Safe because everything under test runs on the MainActor.
@MainActor
func waitUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<1000 where !condition() {
        await Task.yield()
    }
}

/// Waits until an `async` condition holds (state on a non-MainActor actor), sleeping between polls.
/// Records an Issue when the anti-hang ceiling expires — the ceiling is a hang detector, never part
/// of the assertion, and it rides CITimeScale so an oversubscribed runner can't trip it.
func waitUntil(
    _ comment: Comment,
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async {
    let clock = ContinuousClock()
    let start = clock.now
    let ceiling: Duration = CITimeScale.seconds(10)
    while start.duration(to: clock.now) < ceiling {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record(comment)
}
