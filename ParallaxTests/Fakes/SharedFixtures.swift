import Foundation
import ParallaxCore
import ParallaxJellyfin
@testable import Parallax

// Canonical domain fixtures for the app test target. Everything here was, until this file
// existed, a private builder copy-pasted across suites — a Session literal in five files, a
// Movie literal in five more, an `SMBServerData` literal in six. One copy each now, every
// field defaulted to the value the majority of callers used, so a suite that needs a
// different shape passes an argument instead of re-spelling the literal.
//
// Deliberately NOT importing `ParallaxCoreTestSupport`: it's a SECOND product of the
// ParallaxCore package, and a sibling product duplicates ParallaxCore in the app-hosted
// bundle, breaking cross-boundary `as AppError` casts — same reason `Fakes/FakeKeychain.swift`
// stays a local copy.
//
// Player-side fixtures (`PlayerFixtures`, the audio-session stubs, `makePlayerVM`) live in
// `Fakes/PlayerViewModelFixtures.swift`, which already carries the ParallaxPlayback imports.

// MARK: - Jellyfin sessions

/// A live Jellyfin `Session` for server `id`. `name` overrides the derived display name for
/// the suites that assert on section titles; the user snapshot and token are derived from the
/// id so two sessions never collide.
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

/// The one-server `MediaSourceID` the single-source grid/user-data suites key everything on.
var testJellyfinSource: MediaSourceID { .jellyfin(ServerID(rawValue: "test-server")) }

// MARK: - Library items

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
func makeEpisode(
    _ id: String,
    name: String? = nil,
    seriesID: String = "series",
    isFavorite: Bool = false
) -> Episode {
    Episode(
        id: ItemID(rawValue: id), seriesID: ItemID(rawValue: seriesID),
        seasonID: ItemID(rawValue: "\(seriesID)-s1"), name: name ?? id,
        seriesName: nil, indexNumber: nil, parentIndexNumber: nil,
        overview: nil, runtime: nil, primaryTag: nil,
        userData: UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: isFavorite)
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

// MARK: - SMB servers

func makeSMBServerData(
    host: String = "nas.local",
    username: String = "alice",
    domain: String = "WORKGROUP",
    shares: [String] = ["Media"]
) -> SMBServerData {
    SMBServerData(host: host, username: username, domain: domain, shares: shares)
}

/// An `SMBServerRef` over `makeSMBServerData`. The default id is the `host|share|path` shape
/// `ServerStore` mints, because the resolver suites seed a Keychain slot keyed on it.
func makeSMBRef(
    id: String = "smb-nas|Media|Movies",
    host: String = "nas.local",
    username: String = "alice",
    domain: String = "WORKGROUP",
    shares: [String] = ["Media"]
) -> SMBServerRef {
    SMBServerRef(
        id: ServerID(rawValue: id),
        data: makeSMBServerData(host: host, username: username, domain: domain, shares: shares)
    )
}
