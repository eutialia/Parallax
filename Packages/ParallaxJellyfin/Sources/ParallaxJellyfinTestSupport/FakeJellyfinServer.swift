import Foundation
import Get
import JellyfinAPI
import Observation
import ParallaxJellyfin
import Synchronization
import Testing

/// An in-memory Jellyfin server. It answers through `StubURLProtocol`, so the real jellyfin-sdk
/// request building and response decoding run end to end, and it keeps state across requests:
/// users sign in, tokens are issued and can be revoked, and a favorite or a watched mark the app
/// writes shows up in the next fetch.
///
/// Any client built on `StubHTTPTransport.configuration` reaches it at `url`. It serves only the
/// routes the scenarios have needed so far; anything else records a test issue naming the method
/// and path, which is the next route to add.
///
/// Items are named, and every seeding and progress call addresses them by that name. An episode is
/// named after its series and position, "Severance S1E2", so names stay unique.
public final class FakeJellyfinServer: Observable, Sendable {
    public let name: String
    /// The server's Jellyfin id, which `SessionManager` adopts as the persisted `ServerID`.
    public let id: String

    public enum LibraryKind: Sendable { case movies, shows }

    /// How the server hands a title to the player: the file as it is, or an HLS transcode.
    public enum Delivery: Sendable { case directPlay, transcode }

    /// One audio track of a title, in the order the file carries them.
    public struct AudioTrack: Sendable {
        public let language: String
        public let title: String
        public let codec: String

        public init(language: String, title: String, codec: String = "aac") {
            self.language = language
            self.title = title
            self.codec = codec
        }
    }

    /// A subtitle track. Text is an external SRT the server serves verbatim; an image track
    /// (PGS) can only reach the player burned into a transcode.
    public struct SubtitleTrack: Sendable {
        public enum Content: Sendable {
            case srt(String)
            /// An SRT the server serves as bytes that aren't UTF-8 text: it answers, and nothing
            /// can draw what it sent.
            case garbledSRT
            case image
        }

        public let language: String
        public let title: String
        public let content: Content

        public init(language: String, title: String, _ content: Content) {
            self.language = language
            self.title = title
            self.content = content
        }
    }

    /// One PlaybackInfo negotiation the player asked for.
    public struct PlaybackRequest: Equatable, Sendable {
        public let item: String
        public let startSeconds: Int?
        public let audioStreamIndex: Int?
        public let subtitleStreamIndex: Int?
        /// Whether the device profile accepted bare Dolby Vision HEVC, which only a device that
        /// decodes it in hardware declares.
        public let acceptsDolbyVision: Bool

        public init(
            item: String, startSeconds: Int?, audioStreamIndex: Int? = nil, subtitleStreamIndex: Int? = nil,
            acceptsDolbyVision: Bool = false
        ) {
            self.item = item
            self.startSeconds = startSeconds
            self.audioStreamIndex = audioStreamIndex
            self.subtitleStreamIndex = subtitleStreamIndex
            self.acceptsDolbyVision = acceptsDolbyVision
        }
    }

    /// One playback report the player sent, at the position it reported.
    public struct PlaybackReport: Equatable, Sendable {
        public enum Kind: Sendable { case started, progress, stopped }
        public let kind: Kind
        public let item: String
        public let seconds: Int

        public init(_ kind: Kind, _ item: String, at seconds: Int) {
            self.kind = kind
            self.item = item
            self.seconds = seconds
        }
    }

    private struct User {
        let id: String
        let name: String
        let password: String
    }

    private struct PendingQuickConnect {
        let code: String
        var approvedUserID: String?
    }

    private struct Library {
        let name: String
        let kind: LibraryKind
        var id: String { "library-\(name)" }
    }

    private struct CatalogItem {
        let id: String
        let kind: BaseItemKind
        let name: String
        var libraryID: String?
        var seriesID: String?
        var seriesName: String?
        var seasonID: String?
        var seasonNumber: Int?
        var episodeNumber: Int?
        var genres: [String] = []
        var year: Int?
        var minutes: Int?
        var positionTicks = 0
        var played = false
        var isFavorite = false
        var lastPlayed: Date?
        var delivery = Delivery.directPlay
        var audio = [AudioTrack(language: "eng", title: "English")]
        var subtitles: [SubtitleTrack] = []
        var intro: (start: Int, end: Int)?
    }

    private struct State {
        var version = "12.2.0"
        var users: [User] = []
        var libraries: [Library] = []
        var catalog: [CatalogItem] = []
        var tokens: [String: String] = [:]
        var quickConnects: [String: PendingQuickConnect] = [:]
        var issuedQuickConnects = 0
        var isDown = false
        var configurations: [String: UserConfiguration] = [:]
        var playSessions = 0
        var playbackRequests: [PlaybackRequest] = []
        var playbackReports: [PlaybackReport] = []
    }

    private let transport = StubHTTPTransport()
    private let state = Mutex(State())
    /// Tells `Observations` a request was answered, so a wait on the server's ledgers re-reads them.
    private let registrar = ObservationRegistrar()

    public init(name: String = "Jellyfin") {
        self.name = name
        self.id = "server-\(UUID().uuidString.lowercased())"
        transport.respond { [weak self] exchange in
            guard let self else { return StubHTTPTransport.Reply(status: 503) }
            let reply = answer(exchange)
            // On the main actor, where the waits observe: `Observations` installs its tracking
            // after its read returns, so a change announced from this loading thread in that gap
            // would be lost.
            Task { @MainActor in
                registrar.withMutation(of: self, keyPath: \.playbackReports) {}
                registrar.withMutation(of: self, keyPath: \.playbackRequests) {}
            }
            return reply
        }
    }

    public var url: URL { transport.baseURL }

    // MARK: - Seeding

    @discardableResult
    public func user(_ name: String, password: String = "") -> Self {
        state.withLock { $0.users.append(User(id: "user-\(name)", name: name, password: password)) }
        return self
    }

    /// `username` prefers subtitles in `language`, always shown, as an earlier remembered pick leaves it.
    @discardableResult
    public func subtitleLanguage(_ language: String, for username: String) -> Self {
        state.withLock { state in
            let id = state.users.first { $0.name == username }!.id
            var configuration = state.configurations[id] ?? UserConfiguration()
            configuration.subtitleLanguagePreference = language
            configuration.subtitleMode = .always
            state.configurations[id] = configuration
        }
        return self
    }

    /// `username`'s subtitle language preference as the server stores it.
    public func subtitleLanguage(of username: String) -> String? {
        state.withLock { state in
            state.users.first { $0.name == username }.flatMap { state.configurations[$0.id]?.subtitleLanguagePreference }
        }
    }

    /// The Jellyfin version the server reports, 12.2.0 unless set. Settable mid-test, as a server
    /// that was upgraded or rolled back is.
    @discardableResult
    public func version(_ version: String) -> Self {
        state.withLock { $0.version = version }
        return self
    }

    @discardableResult
    public func library(_ name: String, of kind: LibraryKind = .movies) -> Self {
        state.withLock { $0.libraries.append(Library(name: name, kind: kind)) }
        return self
    }

    @discardableResult
    public func movie(
        _ title: String,
        in library: String,
        year: Int? = nil,
        genres: [String] = [],
        minutes: Int = 120
    ) -> Self {
        state.withLock { state in
            state.catalog.append(CatalogItem(
                id: Self.itemID(title),
                kind: .movie,
                name: title,
                libraryID: Library(name: library, kind: .movies).id,
                genres: genres,
                year: year,
                minutes: minutes
            ))
        }
        return self
    }

    /// A series with `episodes[n]` episodes in season n + 1, each 50 minutes long.
    @discardableResult
    public func series(_ title: String, in library: String, episodes: [Int]) -> Self {
        state.withLock { state in
            let seriesID = Self.itemID(title)
            state.catalog.append(CatalogItem(
                id: seriesID, kind: .series, name: title, libraryID: Library(name: library, kind: .shows).id
            ))
            for (offset, count) in episodes.enumerated() {
                let season = offset + 1
                let seasonID = "\(seriesID)-season-\(season)"
                state.catalog.append(CatalogItem(
                    id: seasonID, kind: .season, name: "Season \(season)",
                    seriesID: seriesID, seriesName: title, seasonNumber: season
                ))
                for episode in 1 ... max(count, 1) where count > 0 {
                    let name = "\(title) S\(season)E\(episode)"
                    state.catalog.append(CatalogItem(
                        id: Self.itemID(name), kind: .episode, name: name,
                        seriesID: seriesID, seriesName: title, seasonID: seasonID,
                        seasonNumber: season, episodeNumber: episode, minutes: 50
                    ))
                }
            }
        }
        return self
    }

    /// Someone watched `title` up to `minutes` in, just now — as a player reporting progress does.
    @discardableResult
    public func watch(_ title: String, minutes: Int) -> Self {
        mutate(title) { item in
            item.positionTicks = minutes * 60 * 10_000_000
            item.played = false
            item.lastPlayed = Self.nextPlayDate()
        }
        return self
    }

    /// Someone finished `title`, just now.
    @discardableResult
    public func finish(_ title: String) -> Self {
        mutate(title) { item in
            item.positionTicks = 0
            item.played = true
            item.lastPlayed = Self.nextPlayDate()
        }
        return self
    }

    /// How `title` plays: its delivery, its audio tracks (English alone unless named) and its
    /// subtitles. Stream indices follow the file: the video is 0, then each audio track, then
    /// each subtitle.
    @discardableResult
    public func streams(
        _ title: String,
        by delivery: Delivery = .directPlay,
        audio: [AudioTrack]? = nil,
        subtitles: [SubtitleTrack] = []
    ) -> Self {
        mutate(title) { item in
            item.delivery = delivery
            if let audio { item.audio = audio }
            item.subtitles = subtitles
        }
        return self
    }

    /// `title` opens with an intro from `start` to `end` seconds in.
    @discardableResult
    public func intro(of title: String, from start: Int, to end: Int) -> Self {
        mutate(title) { item in item.intro = (start, end) }
        return self
    }

    @discardableResult
    public func favorite(_ title: String) -> Self {
        mutate(title) { item in item.isFavorite = true }
        return self
    }

    /// The Jellyfin id the server gave `title`.
    public func itemID(of title: String) -> String {
        Self.itemID(title)
    }

    /// Every PlaybackInfo negotiation so far, in order.
    public var playbackRequests: [PlaybackRequest] {
        registrar.access(self, keyPath: \.playbackRequests)
        return state.withLock { $0.playbackRequests }
    }

    /// Every playing, progress and stopped report so far, in order.
    public var playbackReports: [PlaybackReport] {
        registrar.access(self, keyPath: \.playbackReports)
        return state.withLock { $0.playbackReports }
    }

    /// Whether `title` is a favorite on the server right now.
    public func isFavorite(_ title: String) -> Bool {
        state.withLock { state in state.catalog.first { $0.name == title }?.isFavorite ?? false }
    }

    /// The server is unreachable until `comeBackOnline()`: every request throws a transport
    /// `URLError(.cannotConnectToHost)`, as `URLSession` does against a host that is down. It never
    /// answers an HTTP status.
    public func goOffline() {
        state.withLock { $0.isDown = true }
    }

    public func comeBackOnline() {
        state.withLock { $0.isDown = false }
    }

    /// Which requests `holdResponses(to:)` leaves unanswered.
    public enum HeldRequests: Sendable {
        case all
        /// Only the library list (`/UserViews`).
        case libraryList
        /// Only the PlaybackStopped reports.
        case playbackStops
        /// Only the transcode kills (`/Videos/ActiveEncodings`).
        case encodingKills
        /// Only the subtitle streams, as a server still extracting them answers.
        case subtitles
    }

    /// Leaves the chosen requests from now on unanswered until `releaseResponses()`, which answers
    /// them from the state at that moment.
    public func holdResponses(to held: HeldRequests = .all) {
        switch held {
        case .all:
            transport.holdReplies()
        case .libraryList:
            transport.holdReplies { $0 == Self.path(of: Paths.getUserViews()) }
        case .playbackStops:
            transport.holdReplies { $0 == Self.path(of: Paths.reportPlaybackStopped()) }
        case .encodingKills:
            transport.holdReplies { $0 == Self.path(of: Paths.stopEncodingProcess(deviceID: "", playSessionID: "")) }
        case .subtitles:
            transport.holdReplies { $0.contains("/Subtitles/") }
        }
    }

    public func releaseResponses() {
        transport.releaseReplies()
    }

    /// How many requests `holdResponses(to:)` has left unanswered so far.
    public var heldResponseCount: Int { transport.heldReplyCount }

    /// The session a sign-in as `username` would produce, with its token already issued. Seeds a
    /// device that signed in on an earlier launch.
    public func session(signedInAs username: String) -> Session {
        let (user, token) = state.withLock { state in
            let user = state.users.first { $0.name == username }!
            return (user, issueToken(for: user, in: &state))
        }
        return Session(
            id: ServerID(rawValue: id),
            data: JellyfinServerData(
                serverURL: url,
                serverName: name,
                user: UserSnapshot(id: user.id, name: user.name, serverLastUpdatedAt: nil)
            ),
            accessToken: token
        )
    }

    /// The server's side of Quick Connect: someone already signed in enters `code` under their user
    /// menu. The device that asked for the code gets its token on the next poll.
    public func approveQuickConnect(code: String, as username: String) {
        state.withLock { state in
            guard let user = state.users.first(where: { $0.name == username }),
                  let secret = state.quickConnects.first(where: { $0.value.code == code })?.key
            else {
                Issue.record("FakeJellyfinServer has no pending Quick Connect code \(code) for \(username)")
                return
            }
            state.quickConnects[secret]?.approvedUserID = user.id
        }
    }

    /// Forgets every issued token, the way an admin clearing devices does: the next authenticated
    /// request answers 401.
    public func revokeAllTokens() {
        state.withLock { $0.tokens.removeAll() }
    }

    // MARK: - Routing

    private typealias Handler = @Sendable (FakeJellyfinServer, StubHTTPTransport.Exchange, _ pathID: String) -> StubHTTPTransport.Reply

    /// `Self.pathID` stands in for the one path parameter a route can carry.
    private static let routes: [(route: String, needsUser: Bool, handler: Handler)] = [
        (route(Paths.getPublicSystemInfo), false, { server, _, _ in server.publicSystemInfo() }),
        (route(Paths.authenticateUserByName(AuthenticateUserByName())), false, { server, exchange, _ in server.authenticate(exchange) }),
        (route(Paths.initiateQuickConnect), false, { server, _, _ in server.initiateQuickConnect() }),
        (route(Paths.getQuickConnectState(secret: "")), false, { server, exchange, _ in server.quickConnectState(exchange) }),
        (route(Paths.authenticateWithQuickConnect(QuickConnectDto(secret: ""))), false, { server, exchange, _ in server.authenticateWithQuickConnect(exchange) }),
        (route(Paths.revokeKey(key: pathID)), false, { server, _, token in server.revoke(token) }),
        (route(Paths.getUserViews()), true, { server, _, _ in server.userViews() }),
        (route(Paths.getItems()), true, { server, exchange, _ in server.items(exchange) }),
        (route(Paths.getResumeItems()), true, { server, _, _ in server.resumeItems() }),
        (route(Paths.getNextUp()), true, { server, exchange, _ in server.nextUp(exchange) }),
        (route(Paths.getLatestMedia()), true, { _, _, _ in .encoded([BaseItemDto]()) }),
        (route(Paths.getSeasons(seriesID: pathID)), true, { server, _, seriesID in server.seasons(of: seriesID) }),
        (route(Paths.getGenres()), true, { server, exchange, _ in server.genres(exchange) }),
        (route(Paths.markFavoriteItem(itemID: pathID)), true, { server, _, itemID in server.setUserData(itemID) { $0.isFavorite = true } }),
        (route(Paths.unmarkFavoriteItem(itemID: pathID)), true, { server, _, itemID in server.setUserData(itemID) { $0.isFavorite = false } }),
        (route(Paths.markPlayedItem(itemID: pathID)), true, { server, _, itemID in server.setPlayed(itemID, true) }),
        (route(Paths.markUnplayedItem(itemID: pathID)), true, { server, _, itemID in server.setPlayed(itemID, false) }),
        (route(Paths.getCurrentUser), true, { server, exchange, _ in server.currentUser(exchange) }),
        (route(Paths.updateUserConfiguration(UserConfiguration())), true, { server, exchange, _ in server.updateConfiguration(exchange) }),
        (route(Paths.getPostedPlaybackInfo(itemID: pathID)), true, { server, exchange, itemID in server.playbackInfo(itemID, exchange) }),
        (route(Paths.reportPlaybackStart()), true, { server, exchange, _ in server.report(.started, exchange) }),
        (route(Paths.reportPlaybackProgress()), true, { server, exchange, _ in server.report(.progress, exchange) }),
        (route(Paths.reportPlaybackStopped()), true, { server, exchange, _ in server.reportStopped(exchange) }),
        (route(Paths.pingPlaybackSession(playSessionID: "")), true, { _, _, _ in .noContent }),
        (route(Paths.stopEncodingProcess(deviceID: "", playSessionID: "")), true, { _, _, _ in .noContent }),
        (route(Paths.getSessions()), true, { _, _, _ in .encoded([SessionInfoDto]()) }),
        (route(Paths.getItemSegments(itemID: pathID)), true, { server, _, itemID in server.segments(of: itemID) }),
        (route(Paths.getEpisodes(seriesID: pathID)), true, { server, exchange, seriesID in server.episodes(of: seriesID, exchange) }),
        (route(Paths.getSubtitle(routeItemID: pathID, routeMediaSourceID: pathID, routeIndex: indexPlaceholder, routeFormat: pathID))
            .replacing(String(indexPlaceholder), with: pathID), true, { server, exchange, _ in server.subtitle(exchange) }),
    ]

    private func answer(_ exchange: StubHTTPTransport.Exchange) -> StubHTTPTransport.Reply {
        if state.withLock({ $0.isDown }) { return .failure(.cannotConnectToHost) }
        let requested = "\(exchange.method) \(exchange.path)"
        for entry in Self.routes {
            guard let pathID = Self.match(requested, entry.route) else { continue }
            if entry.needsUser, authenticatedUser(exchange) == nil { return StubHTTPTransport.Reply(status: 401) }
            return entry.handler(self, exchange, pathID)
        }
        Issue.record("FakeJellyfinServer has no route for \(requested)")
        return StubHTTPTransport.Reply(status: 501)
    }

    private static let pathID = "PATHID"
    /// Stands in for an integer path parameter, which `Paths` can't take as `pathID`.
    private static let indexPlaceholder = Int.min

    private static func route<Response>(_ request: Request<Response>) -> String {
        "\(request.method.rawValue) \(path(of: request))"
    }

    private static func path<Response>(of request: Request<Response>) -> String {
        request.url?.path ?? ""
    }

    /// The last path parameter when `requested` fits `route` ("" when the route has none), else
    /// nil. A parameter can share its segment with fixed text (`Stream.PATHID`).
    private static func match(_ requested: String, _ route: String) -> String? {
        let lhs = requested.split(separator: "/", omittingEmptySubsequences: false)
        let rhs = route.split(separator: "/", omittingEmptySubsequences: false)
        guard lhs.count == rhs.count else { return nil }
        var captured = ""
        for (part, pattern) in zip(lhs, rhs) {
            if let range = pattern.range(of: Self.pathID) {
                let prefix = pattern[..<range.lowerBound], suffix = pattern[range.upperBound...]
                guard part.hasPrefix(prefix), part.hasSuffix(suffix), part.count > prefix.count + suffix.count
                else { return nil }
                captured = String(part.dropFirst(prefix.count).dropLast(suffix.count))
            } else if part != pattern {
                return nil
            }
        }
        return captured
    }

    // MARK: - System and sign-in

    private func publicSystemInfo() -> StubHTTPTransport.Reply {
        .encoded(PublicSystemInfo(id: id, serverName: name, version: state.withLock { $0.version }))
    }

    private func authenticate(_ exchange: StubHTTPTransport.Exchange) -> StubHTTPTransport.Reply {
        guard let body = try? exchange.decodedBody(AuthenticateUserByName.self) else {
            return StubHTTPTransport.Reply(status: 400)
        }
        let signedIn = state.withLock { state -> (User, String)? in
            guard let user = state.users.first(where: { $0.name == body.username && $0.password == (body.pw ?? "") })
            else { return nil }
            return (user, issueToken(for: user, in: &state))
        }
        guard case let (user, token)? = signedIn else { return StubHTTPTransport.Reply(status: 401) }
        return .encoded(AuthenticationResult(
            accessToken: token,
            serverID: id,
            user: UserDto(id: user.id, name: user.name)
        ))
    }

    private func initiateQuickConnect() -> StubHTTPTransport.Reply {
        let (code, secret) = state.withLock { state in
            state.issuedQuickConnects += 1
            let code = String(format: "%06d", 100_000 + state.issuedQuickConnects)
            let secret = "secret-\(UUID().uuidString.lowercased())"
            state.quickConnects[secret] = PendingQuickConnect(code: code)
            return (code, secret)
        }
        return .encoded(QuickConnectResult(code: code, isAuthenticated: false, secret: secret))
    }

    private func quickConnectState(_ exchange: StubHTTPTransport.Exchange) -> StubHTTPTransport.Reply {
        guard let secret = exchange.query("secret"),
              let pending = state.withLock({ $0.quickConnects[secret] })
        else { return StubHTTPTransport.Reply(status: 404) }
        return .encoded(QuickConnectResult(
            code: pending.code, isAuthenticated: pending.approvedUserID != nil, secret: secret
        ))
    }

    private func authenticateWithQuickConnect(_ exchange: StubHTTPTransport.Exchange) -> StubHTTPTransport.Reply {
        guard let body = try? exchange.decodedBody(QuickConnectDto.self) else {
            return StubHTTPTransport.Reply(status: 400)
        }
        let signedIn = state.withLock { state -> (User, String)? in
            guard let userID = state.quickConnects[body.secret]?.approvedUserID,
                  let user = state.users.first(where: { $0.id == userID })
            else { return nil }
            return (user, issueToken(for: user, in: &state))
        }
        guard case let (user, token)? = signedIn else { return StubHTTPTransport.Reply(status: 401) }
        return .encoded(AuthenticationResult(
            accessToken: token,
            serverID: id,
            user: UserDto(id: user.id, name: user.name)
        ))
    }

    private func revoke(_ token: String) -> StubHTTPTransport.Reply {
        state.withLock { _ = $0.tokens.removeValue(forKey: token) }
        return .noContent
    }

    // MARK: - Library

    private func userViews() -> StubHTTPTransport.Reply {
        let libraries = state.withLock { $0.libraries }
        return .encoded(BaseItemDtoQueryResult(
            items: libraries.map { library in
                BaseItemDto(
                    collectionType: library.kind == .movies ? .movies : .tvshows,
                    id: library.id,
                    name: library.name
                )
            },
            totalRecordCount: libraries.count
        ))
    }

    private func items(_ exchange: StubHTTPTransport.Exchange) -> StubHTTPTransport.Reply {
        let catalog = state.withLock { $0.catalog }
        let kinds = Set(exchange.queryValues("includeItemTypes"))
        let ids = Set(exchange.queryValues("ids"))
        let genres = Set(exchange.queryValues("genres"))
        var matched = catalog.filter { item in
            if !ids.isEmpty, !ids.contains(item.id) { return false }
            if !kinds.isEmpty, !kinds.contains(item.kind.rawValue) { return false }
            if let parent = exchange.query("parentId"), item.libraryID != parent, item.seasonID != parent { return false }
            if exchange.queryValues("filters").contains(ItemFilter.isFavorite.rawValue), !item.isFavorite { return false }
            if !genres.isEmpty, genres.isDisjoint(with: item.genres) { return false }
            if let term = exchange.query("searchTerm"), !item.name.localizedCaseInsensitiveContains(term) { return false }
            return true
        }
        if let sortBy = exchange.queryValues("sortBy").first {
            matched = Self.sorted(matched, by: sortBy, descending: exchange.queryValues("sortOrder").first == SortOrder.descending.rawValue)
        }
        let start = exchange.query("startIndex").flatMap(Int.init) ?? 0
        let limit = exchange.query("limit").flatMap(Int.init) ?? matched.count
        let page = matched.dropFirst(start).prefix(limit)
        return .encoded(BaseItemDtoQueryResult(items: page.map(dto), totalRecordCount: matched.count))
    }

    private static func sorted(_ items: [CatalogItem], by field: String, descending: Bool) -> [CatalogItem] {
        let ascending: [CatalogItem] = switch field {
        case ItemSortBy.sortName.rawValue:
            items.sorted { $0.name < $1.name }
        case ItemSortBy.premiereDate.rawValue:
            items.sorted { ($0.year ?? 0, $0.name) < ($1.year ?? 0, $1.name) }
        case ItemSortBy.indexNumber.rawValue:
            items.sorted { ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) < ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0) }
        default:
            items
        }
        return descending ? ascending.reversed() : ascending
    }

    private func resumeItems() -> StubHTTPTransport.Reply {
        let resumable = state.withLock { $0.catalog }
            .filter { $0.positionTicks > 0 && !$0.played }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        return .encoded(BaseItemDtoQueryResult(items: resumable.map(dto), totalRecordCount: resumable.count))
    }

    /// The episode after the last one played, per series, most recently played series first. Asked
    /// about one series, a series with nothing played offers its first episode.
    private func nextUp(_ exchange: StubHTTPTransport.Exchange) -> StubHTTPTransport.Reply {
        let catalog = state.withLock { $0.catalog }
        let seriesFilter = exchange.query("seriesId")
        let candidates: [(next: CatalogItem, lastPlayed: Date)] = catalog
            .filter { $0.kind == .series && (seriesFilter == nil || $0.id == seriesFilter) }
            .compactMap { series in
                let episodes = Self.sorted(catalog.filter { $0.kind == .episode && $0.seriesID == series.id }, by: ItemSortBy.indexNumber.rawValue, descending: false)
                guard let lastPlayedIndex = episodes.lastIndex(where: \.played) else {
                    guard seriesFilter != nil, let first = episodes.first, !first.played else { return nil }
                    return (first, .distantPast)
                }
                guard let next = episodes[(lastPlayedIndex + 1)...].first(where: { !$0.played }) else { return nil }
                return (next, episodes.compactMap(\.lastPlayed).max() ?? .distantPast)
            }
            .sorted { $0.lastPlayed > $1.lastPlayed }
        return .encoded(BaseItemDtoQueryResult(items: candidates.map { dto($0.next) }, totalRecordCount: candidates.count))
    }

    private func seasons(of seriesID: String) -> StubHTTPTransport.Reply {
        let seasons = state.withLock { $0.catalog }.filter { $0.kind == .season && $0.seriesID == seriesID }
        return .encoded(BaseItemDtoQueryResult(items: seasons.map(dto), totalRecordCount: seasons.count))
    }

    private func genres(_ exchange: StubHTTPTransport.Exchange) -> StubHTTPTransport.Reply {
        let catalog = state.withLock { $0.catalog }
        let parent = exchange.query("parentId")
        let favoritesOnly = exchange.query("isFavorite") == "true"
        let names = Set(catalog
            .filter { (parent == nil || $0.libraryID == parent) && (!favoritesOnly || $0.isFavorite) }
            .flatMap(\.genres))
            .sorted()
        return .encoded(BaseItemDtoQueryResult(items: names.map { BaseItemDto(name: $0) }, totalRecordCount: names.count))
    }

    // MARK: - User data

    private func setUserData(_ itemID: String, _ change: (inout CatalogItem) -> Void) -> StubHTTPTransport.Reply {
        let updated = state.withLock { state -> CatalogItem? in
            guard let index = state.catalog.firstIndex(where: { $0.id == itemID }) else { return nil }
            change(&state.catalog[index])
            return state.catalog[index]
        }
        guard let updated else { return StubHTTPTransport.Reply(status: 404) }
        return .encoded(userData(updated))
    }

    /// Marking a series cascades to every one of its episodes, as Jellyfin does.
    private func setPlayed(_ itemID: String, _ played: Bool) -> StubHTTPTransport.Reply {
        state.withLock { state in
            for index in state.catalog.indices where state.catalog[index].seriesID == itemID && state.catalog[index].kind == .episode {
                state.catalog[index].played = played
                state.catalog[index].positionTicks = 0
            }
        }
        return setUserData(itemID) { item in
            item.played = played
            item.positionTicks = 0
        }
    }

    // MARK: - Playback

    private func currentUser(_ exchange: StubHTTPTransport.Exchange) -> StubHTTPTransport.Reply {
        guard let userID = authenticatedUser(exchange) else { return StubHTTPTransport.Reply(status: 401) }
        let (user, configuration) = state.withLock { state in
            (state.users.first { $0.id == userID }, state.configurations[userID] ?? UserConfiguration())
        }
        return .encoded(UserDto(configuration: configuration, id: userID, name: user?.name))
    }

    private func updateConfiguration(_ exchange: StubHTTPTransport.Exchange) -> StubHTTPTransport.Reply {
        guard let userID = authenticatedUser(exchange),
              let configuration = try? exchange.decodedBody(UserConfiguration.self)
        else { return StubHTTPTransport.Reply(status: 400) }
        state.withLock { $0.configurations[userID] = configuration }
        return .noContent
    }

    /// Plays the requested audio track, else the first; the subtitle is left for the client to
    /// pick. A transcode answers with an HLS playlist, direct play with the file.
    private func playbackInfo(_ itemID: String, _ exchange: StubHTTPTransport.Exchange) -> StubHTTPTransport.Reply {
        guard let body = try? exchange.decodedBody(PlaybackInfoDto.self) else { return StubHTTPTransport.Reply(status: 400) }
        let hevcRanges = body.deviceProfile?.codecProfiles?
            .first { $0.codec == "hevc" }?.conditions?
            .first { $0.property == .videoRangeType }?.value ?? ""
        let answer = state.withLock { state -> (CatalogItem, String)? in
            guard let item = state.catalog.first(where: { $0.id == itemID }) else { return nil }
            state.playSessions += 1
            state.playbackRequests.append(PlaybackRequest(
                item: item.name,
                startSeconds: body.startTimeTicks.map { $0 / 10_000_000 },
                audioStreamIndex: body.audioStreamIndex,
                subtitleStreamIndex: body.subtitleStreamIndex,
                acceptsDolbyVision: hevcRanges.split(separator: "|").contains("DOVI")
            ))
            return (item, "play-session-\(state.playSessions)")
        }
        guard let (item, playSessionID) = answer else { return StubHTTPTransport.Reply(status: 404) }
        let audioIndices = item.audio.indices.map { $0 + 1 }
        let streams = [MediaStream(codec: "h264", height: 1080, index: 0, type: .video, width: 1920)]
            + zip(audioIndices, item.audio).map { index, track in
                MediaStream(channels: 2, codec: track.codec, displayTitle: track.title, index: index,
                            isDefault: index == 1, isExternal: false, language: track.language, type: .audio)
            }
            + item.subtitles.enumerated().map { offset, track in
                let isText = if case .image = track.content { false } else { true }
                return MediaStream(
                    codec: isText ? "subrip" : "pgssub",
                    deliveryMethod: isText ? .external : .encode,
                    displayTitle: track.title, index: 1 + item.audio.count + offset, isDefault: false,
                    isExternal: isText, isForced: false, isTextSubtitleStream: isText,
                    language: track.language, type: .subtitle
                )
            }
        let source = MediaSourceInfo(
            container: item.delivery == .directPlay ? "mp4" : "mkv",
            defaultAudioStreamIndex: body.audioStreamIndex ?? audioIndices.first,
            id: "source-\(item.id)",
            mediaStreams: streams,
            runTimeTicks: item.minutes.map { $0 * 60 * 10_000_000 },
            transcodingURL: item.delivery == .transcode
                ? "/videos/\(item.id)/master.m3u8?PlaySessionId=\(playSessionID)" : nil
        )
        return .encoded(PlaybackInfoResponse(mediaSources: [source], playSessionID: playSessionID))
    }

    /// A report moves the item's saved position, as Jellyfin's session tracking does.
    private func report(_ kind: PlaybackReport.Kind, _ exchange: StubHTTPTransport.Exchange) -> StubHTTPTransport.Reply {
        guard let info = try? exchange.decodedBody(PlaybackStateInfo.self), let itemID = info.itemID else {
            return StubHTTPTransport.Reply(status: 400)
        }
        return record(kind, itemID: itemID, positionTicks: info.positionTicks ?? 0)
    }

    private func reportStopped(_ exchange: StubHTTPTransport.Exchange) -> StubHTTPTransport.Reply {
        guard let info = try? exchange.decodedBody(PlaybackStopInfo.self), let itemID = info.itemID else {
            return StubHTTPTransport.Reply(status: 400)
        }
        return record(.stopped, itemID: itemID, positionTicks: info.positionTicks ?? 0)
    }

    private func record(_ kind: PlaybackReport.Kind, itemID: String, positionTicks: Int) -> StubHTTPTransport.Reply {
        state.withLock { state in
            guard let index = state.catalog.firstIndex(where: { $0.id == itemID }) else { return }
            state.catalog[index].positionTicks = positionTicks
            state.catalog[index].lastPlayed = Self.nextPlayDate()
            state.playbackReports.append(PlaybackReport(
                kind, state.catalog[index].name, at: positionTicks / 10_000_000
            ))
        }
        return .noContent
    }

    private func segments(of itemID: String) -> StubHTTPTransport.Reply {
        let intro = state.withLock { state in state.catalog.first { $0.id == itemID }?.intro }
        let segments = intro.map { intro in
            [MediaSegmentDto(endTicks: intro.end * 10_000_000, id: "intro-\(itemID)", itemID: itemID,
                             startTicks: intro.start * 10_000_000, type: .intro)]
        } ?? []
        return .encoded(MediaSegmentDtoQueryResult(items: segments, totalRecordCount: segments.count))
    }

    /// Asked for the episodes `adjacentTo` one, answers it with its neighbors in airing order,
    /// across seasons.
    private func episodes(of seriesID: String, _ exchange: StubHTTPTransport.Exchange) -> StubHTTPTransport.Reply {
        let catalog = state.withLock { $0.catalog }
        let episodes = Self.sorted(catalog.filter { $0.kind == .episode && $0.seriesID == seriesID },
                                   by: ItemSortBy.indexNumber.rawValue, descending: false)
        guard let adjacentTo = exchange.query("adjacentTo") else {
            return .encoded(BaseItemDtoQueryResult(items: episodes.map(dto), totalRecordCount: episodes.count))
        }
        guard let index = episodes.firstIndex(where: { $0.id == adjacentTo }) else {
            return .encoded(BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }
        let window = Array(episodes[max(index - 1, 0) ... min(index + 1, episodes.count - 1)])
        return .encoded(BaseItemDtoQueryResult(items: window.map(dto), totalRecordCount: window.count))
    }

    /// `/Videos/{item}/{source}/Subtitles/{index}/Stream.{format}`: the subtitle file at that
    /// stream index, as written.
    private func subtitle(_ exchange: StubHTTPTransport.Exchange) -> StubHTTPTransport.Reply {
        let parts = exchange.path.split(separator: "/").map(String.init)
        guard parts.count == 6, let streamIndex = Int(parts[4]) else { return StubHTTPTransport.Reply(status: 400) }
        let content = state.withLock { state -> SubtitleTrack.Content? in
            guard let item = state.catalog.first(where: { $0.id == parts[1] }) else { return nil }
            let offset = streamIndex - 1 - item.audio.count
            return item.subtitles.indices.contains(offset) ? item.subtitles[offset].content : nil
        }
        switch content {
        case .srt(let srt)?:
            return StubHTTPTransport.Reply(headers: ["Content-Type": "text/plain"], body: Data(srt.utf8))
        case .garbledSRT?:
            return StubHTTPTransport.Reply(headers: ["Content-Type": "text/plain"], body: Data([0xC3, 0x28, 0xA0, 0xA1]))
        case .image?, nil:
            return StubHTTPTransport.Reply(status: 404)
        }
    }

    // MARK: - Encoding

    private func dto(_ item: CatalogItem) -> BaseItemDto {
        BaseItemDto(
            genres: item.genres,
            id: item.id,
            indexNumber: item.kind == .season ? item.seasonNumber : item.episodeNumber,
            name: item.name,
            parentID: item.libraryID ?? item.seasonID ?? item.seriesID,
            parentIndexNumber: item.kind == .episode ? item.seasonNumber : nil,
            premiereDate: item.year.flatMap { DateComponents(calendar: .init(identifier: .gregorian), year: $0, month: 1, day: 1).date },
            productionYear: item.year,
            runTimeTicks: item.minutes.map { $0 * 60 * 10_000_000 },
            seasonID: item.seasonID,
            seriesID: item.seriesID,
            seriesName: item.seriesName,
            type: item.kind,
            userData: userData(item)
        )
    }

    private func userData(_ item: CatalogItem) -> UserItemDataDto {
        UserItemDataDto(
            isFavorite: item.isFavorite,
            isPlayed: item.played,
            itemID: item.id,
            key: item.id,
            lastPlayedDate: item.lastPlayed,
            playCount: item.played ? 1 : 0,
            playbackPositionTicks: item.positionTicks
        )
    }

    // MARK: - State

    private func mutate(_ title: String, _ change: (inout CatalogItem) -> Void) {
        state.withLock { state in
            guard let index = state.catalog.firstIndex(where: { $0.name == title }) else {
                Issue.record("FakeJellyfinServer has no item named \(title)")
                return
            }
            change(&state.catalog[index])
        }
    }

    /// The token rides the `MediaBrowser` Authorization header, or the `ApiKey` query on the URLs a
    /// player fetches without headers (streams, subtitles). Like Jellyfin 12 with legacy
    /// authorization off, nothing else counts: no `X-Emby-*` headers, no `api_key`.
    private func authenticatedUser(_ exchange: StubHTTPTransport.Exchange) -> String? {
        let header = exchange.headers["Authorization"]
            .flatMap { $0.hasPrefix("MediaBrowser ") ? $0.firstMatch(of: /Token=([^,\s]+)/) : nil }
            .map { String($0.1) }
        guard let token = header ?? exchange.query("ApiKey") else { return nil }
        return state.withLock { $0.tokens[token] }
    }

    private func issueToken(for user: User, in state: inout State) -> String {
        let token = "token-\(UUID().uuidString.lowercased())"
        state.tokens[token] = user.id
        return token
    }

    private static func itemID(_ name: String) -> String {
        "item-" + name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
    }

    /// Plays happen in order, a minute apart and across every server, so "most recently played"
    /// is unambiguous even between two servers.
    private static let plays = Mutex(0)

    private static func nextPlayDate() -> Date {
        let play = plays.withLock { count in
            count += 1
            return count
        }
        return Date(timeIntervalSince1970: 1_800_000_000 + Double(play) * 60)
    }
}
