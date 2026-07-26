import Foundation
import JellyfinAPI
import ParallaxCore
import ParallaxCoreTestSupport
import Testing
@testable import ParallaxJellyfin

/// The ONE place this target builds sessions, device identities, DTOs, capability sets and
/// `ServerStore` scaffolding. Every suite previously carried its own near-identical copy of
/// `sampleSession()` / `dtoMovie()` / `caps()` / `freshStore()`; a drift between two copies
/// silently changed what a test proved, so they all route through here now.
enum JellyfinFixtures {

    // MARK: - Sessions & identity

    static func session(
        id: String = "s1",
        token: String = "tok-1",
        serverURL: URL? = nil,
        serverName: String? = nil,
        userID: String? = nil,
        userName: String = "alice"
    ) -> Session {
        Session(
            id: ServerID(rawValue: id),
            data: jellyfinData(
                id: id,
                serverURL: serverURL,
                serverName: serverName,
                userID: userID,
                userName: userName
            ),
            accessToken: token
        )
    }

    static func jellyfinData(
        id: String = "s1",
        serverURL: URL? = nil,
        serverName: String? = nil,
        userID: String? = nil,
        userName: String = "alice"
    ) -> JellyfinServerData {
        JellyfinServerData(
            serverURL: serverURL ?? URL(string: "https://\(id).example.com")!,
            serverName: serverName ?? "Server \(id)",
            user: UserSnapshot(id: userID ?? "u-\(id)", name: userName, serverLastUpdatedAt: nil)
        )
    }

    static func persistedJellyfin(id: String, serverName: String? = nil) -> PersistedServer {
        PersistedServer(id: ServerID(rawValue: id), kind: .jellyfin(jellyfinData(id: id, serverName: serverName)))
    }

    static func identity(
        client: String = "Parallax",
        deviceName: String = "Tester",
        deviceID: String = "dev-1",
        version: String = "1.0"
    ) -> DeviceIdentity {
        DeviceIdentity(client: client, deviceName: deviceName, deviceID: deviceID, version: version)
    }

    static func smbData(
        host: String = "nas.local",
        username: String = "alice",
        domain: String = "WORKGROUP",
        shares: [String] = ["Media", "Backups"]
    ) -> SMBServerData {
        SMBServerData(host: host, username: username, domain: domain, shares: shares)
    }

    // MARK: - Keychain

    /// The secret slot for a server, derived from the SAME production helper the store uses —
    /// never a re-typed `"token-<id>"` literal.
    static func tokenKey(for id: ServerID) -> KeychainKey<String> {
        KeychainKey<String>(account: ServerStore.tokenAccount(for: id))
    }

    static func tokenKey(forRawID id: String) -> KeychainKey<String> {
        tokenKey(for: ServerID(rawValue: id))
    }

    // MARK: - UserDefaults / ServerStore scaffolding

    /// A private, empty defaults domain. The suite name is returned so a test can re-open the
    /// same domain (a cold-reload check) or seed raw bytes into it.
    static func freshDefaults(_ label: String) -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "\(label)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    static func settingsStore(_ label: String) -> (settings: SettingsStore, suiteName: String) {
        let (defaults, suiteName) = freshDefaults(label)
        return (SettingsStore(defaults: defaults), suiteName)
    }

    struct StoreHarness {
        let store: ServerStore
        let settings: SettingsStore
        let keychain: FakeKeychain
        let suiteName: String
    }

    static func serverStore(_ label: String = "ServerStore") -> StoreHarness {
        let (settings, suiteName) = settingsStore(label)
        let keychain = FakeKeychain()
        return StoreHarness(
            store: ServerStore(settings: settings, keychain: keychain),
            settings: settings,
            keychain: keychain,
            suiteName: suiteName
        )
    }

    /// Writes `bytes` under the production persisted-servers key so `load()` reads exactly what a
    /// shipped build would have written.
    static func seedPersistedBytes(_ bytes: Data, suiteName: String) {
        let seeder = UserDefaults(suiteName: suiteName)!
        seeder.removePersistentDomain(forName: suiteName)
        seeder.set(bytes, forKey: ServerStore.persistedServersKey.name)
    }

    static func seedPersistedServers(_ servers: [PersistedServer], suiteName: String) throws {
        seedPersistedBytes(try JSONEncoder().encode(servers), suiteName: suiteName)
    }

    static func rawPersistedBytes(suiteName: String) -> Data? {
        UserDefaults(suiteName: suiteName)!.data(forKey: ServerStore.persistedServersKey.name)
    }

    /// Re-reads the persisted array through a FRESH `SettingsStore`, i.e. what the next launch sees.
    static func rereadPersistedServers(suiteName: String) async throws -> [PersistedServer]? {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        return try await settings.tryValue(for: ServerStore.persistedServersKey)
    }

    // MARK: - DTO builders

    static func movieDto(
        id: String = "m1",
        name: String? = nil,
        dateCreated: Date? = nil,
        streams: [MediaStream]? = nil,
        chapters: [ChapterInfo]? = nil
    ) -> BaseItemDto {
        var dto = BaseItemDto()
        dto.id = id
        dto.name = name ?? "Movie \(id)"
        dto.type = .movie
        dto.dateCreated = dateCreated
        dto.mediaStreams = streams
        dto.chapters = chapters
        return dto
    }

    static func seriesDto(
        id: String = "ser-1",
        name: String? = nil,
        dateCreated: Date? = nil,
        imageTags: [String: String]? = nil
    ) -> BaseItemDto {
        var dto = BaseItemDto()
        dto.id = id
        dto.name = name ?? "Series \(id)"
        dto.type = .series
        dto.dateCreated = dateCreated
        dto.imageTags = imageTags
        return dto
    }

    static func seasonDto(
        id: String = "sea-1",
        seriesID: String = "ser-1",
        indexNumber: Int? = 1,
        imageTags: [String: String]? = nil
    ) -> BaseItemDto {
        var dto = BaseItemDto()
        dto.id = id
        dto.name = "Season \(id)"
        dto.type = .season
        dto.seriesID = seriesID
        dto.indexNumber = indexNumber
        dto.imageTags = imageTags
        return dto
    }

    static func episodeDto(
        id: String = "ep-1",
        seriesID: String = "ser-1",
        seasonID: String = "sea-1",
        indexNumber: Int? = nil,
        parentIndexNumber: Int? = nil,
        dateCreated: Date? = nil
    ) -> BaseItemDto {
        var dto = BaseItemDto()
        dto.id = id
        dto.name = "Episode \(id)"
        dto.type = .episode
        dto.seriesID = seriesID
        dto.seasonID = seasonID
        dto.indexNumber = indexNumber
        dto.parentIndexNumber = parentIndexNumber
        dto.dateCreated = dateCreated
        return dto
    }

    static func collectionDto(
        id: String = "coll-movies",
        name: String = "Movies",
        collectionType: JellyfinAPI.CollectionType? = .movies,
        primaryTag: String? = "p-tag"
    ) -> BaseItemDto {
        var dto = BaseItemDto()
        dto.id = id
        dto.name = name
        dto.collectionType = collectionType
        dto.imageTags = primaryTag.map { ["Primary": $0] }
        return dto
    }

    // MARK: - Capabilities

    /// The AVKit-only tier every URL/profile suite starts from. `software*` default to empty so a
    /// caller opts INTO the VLC tier explicitly — the discriminating variable in those suites.
    static func caps(
        videoCodecs: [VideoCodec] = [.h264, .hevc],
        audioCodecs: [AudioCodec] = [.aac, .ac3, .eac3, .mp3],
        containers: [Container] = [.mp4, .mov, .hls],
        hdr: HDRSupport = .none,
        maxResolution: Resolution = .uhd4K,
        maxBitrate: Bitrate = .megabits(120),
        audioOutput: AudioOutputCapability = .stereo,
        subtitleFormats: [SubtitleFormat] = [.vtt, .srt],
        softwareVideoCodecs: [VideoCodec] = [],
        softwareAudioCodecs: [AudioCodec] = [],
        softwareContainers: [Container] = []
    ) -> DeviceCapabilities {
        DeviceCapabilities(
            supportedVideoCodecs: videoCodecs,
            supportedAudioCodecs: audioCodecs,
            supportedContainers: containers,
            hdr: hdr,
            maxResolution: maxResolution,
            maxBitrate: maxBitrate,
            audioOutput: audioOutput,
            preferredSubtitleFormats: subtitleFormats,
            softwareVideoCodecs: softwareVideoCodecs,
            softwareAudioCodecs: softwareAudioCodecs,
            softwareContainers: softwareContainers
        )
    }

    // MARK: - Domain-model builders

    static func movie(
        id: String = "m1",
        title: String? = nil,
        dateAdded: Date? = nil,
        primaryTag: ImageTag? = nil,
        backdropTags: [ImageTag] = [],
        logoTag: ImageTag? = nil,
        thumbTag: ImageTag? = nil,
        userData: UserItemData = .absent
    ) -> Movie {
        Movie(
            id: ItemID(rawValue: id),
            title: title ?? "Movie \(id)",
            overview: nil,
            year: nil,
            runtime: nil,
            communityRating: nil,
            officialRating: nil,
            genres: [],
            primaryTag: primaryTag,
            backdropTags: backdropTags,
            logoTag: logoTag,
            thumbTag: thumbTag,
            dateAdded: dateAdded,
            userData: userData
        )
    }

    static func episode(
        id: String = "e1",
        seriesID: String = "ser-1",
        seasonID: String = "sea-1",
        name: String? = nil,
        seriesName: String? = nil,
        indexNumber: Int? = 1,
        parentIndexNumber: Int? = 1,
        runtime: Duration? = nil,
        primaryTag: ImageTag? = nil,
        dateAdded: Date? = nil,
        userData: UserItemData = .absent
    ) -> Episode {
        Episode(
            id: ItemID(rawValue: id),
            seriesID: ItemID(rawValue: seriesID),
            seasonID: ItemID(rawValue: seasonID),
            name: name ?? "Episode \(id)",
            seriesName: seriesName,
            indexNumber: indexNumber,
            parentIndexNumber: parentIndexNumber,
            overview: nil,
            runtime: runtime,
            primaryTag: primaryTag,
            dateAdded: dateAdded,
            userData: userData
        )
    }
}

/// Names the memoization contract every per-server store shares: same key → same instance,
/// distinct key → distinct instance, rotated token → rebuilt instance. Each store owns a
/// different vended type, so the contract is expressed once here and applied three times.
func verifyMemoization<Value: AnyObject>(
    make: (Session) async -> Value,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let first = await make(JellyfinFixtures.session(id: "a", token: "tok-a"))
    let again = await make(JellyfinFixtures.session(id: "a", token: "tok-a"))
    #expect(first === again, "the same server + token must reuse one instance", sourceLocation: sourceLocation)

    let otherServer = await make(JellyfinFixtures.session(id: "b", token: "tok-a"))
    #expect(first !== otherServer, "a different server must get its own instance", sourceLocation: sourceLocation)

    let rotated = await make(JellyfinFixtures.session(id: "a", token: "tok-rotated"))
    #expect(first !== rotated, "a rotated token must rebuild the instance", sourceLocation: sourceLocation)
}
