import Foundation
import ParallaxCore
import ParallaxCoreTestSupport
import ParallaxFeatures
import ParallaxFileBrowse
import ParallaxFileBrowseTestSupport
import ParallaxJellyfin
import ParallaxJellyfinTestSupport
import ParallaxPlayback
import ParallaxPlaybackTestSupport
import ParallaxTestScaling
import Synchronization
import Testing

/// The real `AppModel` on fake edges. Scenarios drive it through the methods the views call and
/// assert on the state the views render.
///
/// Faked: the Keychain, `UserDefaults` (a private suite), the storage and caches directories (a
/// scratch directory), the Jellyfin transport (`FakeJellyfinServer`s), the LAN discovery broadcast,
/// the SMB connections under the real pool (`nas`), Bonjour browsing, the clock, reachability
/// (scripted, online until told otherwise), the capability probe, the audio session, the frame
/// thumbnailer, the playback engines (`engines`), Now Playing, the display and VLC's subtitle fonts.
@MainActor
final class AppWorld {
    private(set) var app: AppModel
    let clock: TestClock
    /// Every SMB host the app connects to; scenarios script one NAS.
    let nas: FakeSMBWorld
    let thumbnailer: RecordingThumbnailer
    /// Every playback engine the app built, in build order. The last one is playing.
    let engines: EngineLedger
    private let keychain: FakeKeychain
    private let bonjour: ScriptedBonjour
    private let reachability: ScriptedReachability

    private let environment: AppEnvironment
    /// The servers live as long as the world: their stub hosts route only while they exist.
    private let servers: [FakeJellyfinServer]
    private let suiteName: String
    private let storageDirectory: URL
    private var lifetime: Task<Void, Never>
    /// The open player, as the player view holds it.
    private(set) var player: PlayerViewModel?
    /// The player view's `.task`, which runs the player's session.
    private var playerSession: Task<Void, Never>?

    /// Launches the app the way a cold start does: `run()` and `bootstrap()`, as the app root's
    /// tasks call them. `signedIn` accounts and `savedSMB` servers (with their passwords) were saved
    /// by an earlier launch; `discovering` are the servers that answer a LAN discovery broadcast.
    static func launch(
        signedIn accounts: [(server: FakeJellyfinServer, user: String)] = [],
        savedSMB: [(server: SMBServerData, password: String)] = [],
        discovering lanServers: [FakeJellyfinServer] = [],
        launchReveal: LaunchRevealCoverage = .home
    ) async throws -> AppWorld {
        let suiteName = "AppWorld-\(UUID().uuidString)"
        let storageDirectory = URL.temporaryDirectory.appending(path: suiteName, directoryHint: .isDirectory)
        let clock = TestClock()
        let lanReplies = try lanServers.map { server in
            try JSONEncoder().encode(["Address": server.url.absoluteString, "Id": server.id, "Name": server.name])
        }
        let keychain = FakeKeychain()
        let nas = FakeSMBWorld()
        let bonjour = ScriptedBonjour()
        let thumbnailer = RecordingThumbnailer()
        let engines = EngineLedger()
        let reachability = ScriptedReachability()
        let environment = AppEnvironment(
            keychain: keychain,
            defaults: UserDefaults(suiteName: suiteName)!,
            storageDirectory: storageDirectory,
            cachesDirectory: storageDirectory.appending(path: "Caches", directoryHint: .isDirectory),
            urlSessionConfiguration: StubHTTPTransport.configuration,
            clock: clock,
            reachability: reachability,
            capabilityProbe: FakeCapabilityProbe(),
            lanBroadcaster: { _ in lanReplies },
            audioSession: SilentAudioSession(),
            smbConnections: nas.connections(),
            browseSMBServices: { bonjour.browse() },
            thumbnailer: thumbnailer,
            makePlaybackEngine: { id, _ in engines.make(id) },
            makeNowPlaying: { SpyNowPlaying() },
            prepareDisplay: { _ in },
            engineSubtitleFonts: PlayerFixtures.engineSubtitleFonts,
            clientName: "Parallax",
            deviceName: "Scenario Device",
            appVersion: "1.0",
            launchReveal: launchReveal
        )

        let earlierLaunch = AppModel(environment: environment)
        for account in accounts {
            try await earlierLaunch.services.serverStore.add(account.server.session(signedInAs: account.user))
        }
        for saved in savedSMB {
            try await earlierLaunch.services.serverStore.addSMBServer(saved.server, password: saved.password)
        }

        let world = AppWorld(
            environment: environment, servers: accounts.map(\.server) + lanServers, clock: clock,
            nas: nas, thumbnailer: thumbnailer, engines: engines, keychain: keychain, bonjour: bonjour,
            reachability: reachability,
            suiteName: suiteName, storageDirectory: storageDirectory
        )
        await world.app.bootstrap()
        return world
    }

    private init(
        environment: AppEnvironment, servers: [FakeJellyfinServer], clock: TestClock,
        nas: FakeSMBWorld, thumbnailer: RecordingThumbnailer, engines: EngineLedger, keychain: FakeKeychain,
        bonjour: ScriptedBonjour, reachability: ScriptedReachability, suiteName: String, storageDirectory: URL
    ) {
        let app = AppModel(environment: environment)
        self.app = app
        self.environment = environment
        self.servers = servers
        self.clock = clock
        self.nas = nas
        self.thumbnailer = thumbnailer
        self.engines = engines
        self.keychain = keychain
        self.bonjour = bonjour
        self.reachability = reachability
        self.suiteName = suiteName
        self.storageDirectory = storageDirectory
        lifetime = Task { await app.run() }
    }

    /// Quits and cold-launches the app: a new `AppModel` on the same Keychain, defaults and disk.
    func relaunch() async {
        lifetime.cancel()
        let app = AppModel(environment: environment)
        self.app = app
        lifetime = Task { await app.run() }
        await app.bootstrap()
    }

    /// Closes the app and waits for its app-lifetime flows to wind down.
    func quit() async {
        lifetime.cancel()
        await lifetime.value
    }

    deinit {
        lifetime.cancel()
        playerSession?.cancel()
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: storageDirectory)
    }

    /// Waits for state the app reaches asynchronously, and ends the scenario at the caller's line
    /// when it never arrives: every later step would run against the wrong state.
    func until(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        guard try await pollUntil(condition) else { throw StateNeverArrived(awaitedAt: sourceLocation) }
    }

    /// `until`, for state behind an actor.
    func until(_ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + CITimeScale.seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw StateNeverArrived(awaitedAt: sourceLocation) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    struct StateNeverArrived: Error, CustomStringConvertible {
        let awaitedAt: SourceLocation
        var description: String {
            "the app never reached the state awaited at \(awaitedAt.fileName):\(awaitedAt.line)"
        }
    }

    // MARK: - Steps

    /// The signed-in tabs load Home's feed and the library list, as both navigation roots do
    /// whenever the router's reload token moves.
    func openHome() async {
        await app.loadSources()
    }

    /// Opens `library` from the library list, as tapping its row does: the grid, not yet loaded.
    func openLibrary(_ library: String, on server: FakeJellyfinServer) async throws -> LibraryGridViewModel {
        await openHome()
        let entry = try #require(app.libraries.groups.allEntries.first {
            $0.collection.name == library && $0.source.sourceID == .jellyfin(ServerID(rawValue: server.id))
        })
        return await app.libraryGrid(for: entry.collection, on: try await session(on: server))
    }

    /// The session for `server`, as the store holds it after sign-in.
    func session(on server: FakeJellyfinServer) async throws -> Session {
        try #require(await app.services.serverStore.sessions.first { $0.id.rawValue == server.id })
    }

    /// Opens one level of an SMB share, as `SMBBrowseView` does when it appears.
    func openSMBFolder(_ ref: SMBServerRef, share: String, path: String = "") async -> SMBBrowseViewModel {
        let level = app.makeSMBBrowse(SMBBrowsePath(ref: ref, share: share, path: path))
        level.isOnScreen = true
        await level.open()
        return level
    }

    // MARK: - Player

    /// The engine the player is driving: the last one the app built.
    var engine: FakePlaybackEngine { engines.live }

    /// Mounts the player for the presenter's request, as the root host does, and waits until the
    /// engine it built has been told to play.
    @discardableResult
    func openPlayer(sourceLocation: SourceLocation = #_sourceLocation) async throws -> PlayerViewModel {
        let request = try #require(app.playback.request, "nothing asked the player to open", sourceLocation: sourceLocation)
        let built = engines.count
        let app = app
        playerSession = Task { [weak self] in
            await app.runPlayer(for: request, subtitleSurface: { PlayerFixtures.phoneSurface }) { self?.player = $0 }
        }
        try await until({ self.engines.count > built && self.engine.calls.contains("play") }, sourceLocation: sourceLocation)
        return try #require(player, sourceLocation: sourceLocation)
    }

    /// The engine opened the stream and knows how long it is.
    func streamIsReady(duration: Duration, tracks: TrackInventory = .empty) async throws {
        engine.push(.ready(duration: .seconds(duration / .seconds(1)), tracks: tracks))
        try await engine.settle()
    }

    /// Frames are moving at `position` into a stream `duration` long.
    func streamPlays(at position: Duration, of duration: Duration) async throws {
        engine.push(.playing(position / .seconds(1), duration: .seconds(duration / .seconds(1))))
        try await engine.settle()
    }

    /// The stream played to its end.
    func streamEnds() {
        engine.push(.ended)
    }

    /// The engine can't decode the stream it opened.
    func streamFailsToDecode() {
        engine.push(.failed(.assetNotPlayable))
    }

    /// Closes the player the way the Close chevron does: the presenter dismisses, and the view's
    /// disappearance ends the session.
    func closePlayer() async {
        app.playback.dismiss()
        playerSession?.cancel()
        await player?.stop()
        await playerSession?.value
        playerSession = nil
        player = nil
    }

    /// The network drops. Returns once the app has seen it.
    func goOffline() async throws {
        reachability.set(isSatisfied: false)
        try await until { !app.connectivity.isOnline }
    }

    /// The network returns. Returns once the app has seen it.
    func comeOnline() async throws {
        reachability.set(isSatisfied: true)
        try await until { app.connectivity.isOnline }
    }

    /// The first activation of a cold launch, after the first screens are up.
    func settleLaunch() {
        app.lifecycle.update(.active)
    }

    /// The launch stage's first frame, as the overlay's appearance reports it.
    func showLaunchStage() {
        app.launchGate.beginStage()
    }

    /// The user leaves the app, as the app root forwards the scene phase.
    func background() {
        app.lifecycle.update(.inactive)
        app.lifecycle.update(.background)
    }

    /// The user comes back to the app.
    func foreground() {
        app.lifecycle.update(.inactive)
        app.lifecycle.update(.active)
    }

    /// Bonjour now sees exactly these SMB services on the network.
    func advertiseSMB(_ serviceNames: [String]) {
        bonjour.advertise(serviceNames)
    }

    /// The Keychain lost the saved SMB server's password (a device migration, an access-group
    /// change). The account is `ServerStore`'s slot for that server.
    func loseSMBPassword(of ref: SMBServerRef) {
        keychain.setAbsent(account: "token-\(ref.id.rawValue)")
    }

    // MARK: - Readable state

    /// The subtitle style on disk, which a relaunch reads back.
    var persistedSubtitleStyle: SubtitleStyle? {
        environment.defaults.data(forKey: SubtitlePreferences.key.name)
            .flatMap { try? JSONDecoder().decode(SubtitleStyle.self, from: $0) }
    }

    struct SidebarSection: Equatable {
        let title: String
        let libraries: [String]
    }

    /// The library list's sections, titled as the sidebar titles them.
    var sidebar: [SidebarSection] {
        let groups = app.libraries.groups
        return groups.map { SidebarSection(title: groups.sectionTitle(for: $0), libraries: $0.entries.map(\.collection.name)) }
    }

    var continueWatching: [String] { app.home?.continueWatching.map(\.item.displayTitle) ?? [] }
    var nextUp: [String] { app.home?.nextUp.map(\.item.displayTitle) ?? [] }

    /// How far into `title` Continue Watching says the user is.
    func minutesWatched(_ title: String) -> Int? {
        app.home?.continueWatching.first { $0.item.displayTitle == title }
            .map { Int($0.item.userData.playbackPositionTicks / 600_000_000) }
    }

    struct PlayRequest: Equatable {
        let item: String
        let server: String
        let fromBeginning: Bool
        /// The saved position the player resumes from, when the request carries the loaded detail.
        var resumeMinutes: Int?
    }

    /// What the player was asked to open.
    var playRequest: PlayRequest? {
        switch app.playback.request?.target {
        case .detail(let detail, let session, let fromBeginning):
            guard case .movie(let movie) = detail else { return nil }
            return PlayRequest(
                item: movie.movie.id.rawValue,
                server: session.serverName,
                fromBeginning: fromBeginning,
                resumeMinutes: Int(movie.movie.userData.playbackPositionTicks / 600_000_000)
            )
        case .itemID(let itemID, let session, let fromBeginning):
            return PlayRequest(item: itemID.rawValue, server: session.serverName, fromBeginning: fromBeginning)
        case .smb, nil:
            return nil
        }
    }

    /// The SMB libraries the sidebar lists: one `host/share` per selected share, in saved order.
    func smbLibraries() async -> [String] {
        await app.services.serverStore.servers.flatMap { server -> [String] in
            guard case .smb(let data) = server.kind else { return [] }
            return data.shares.map { "\(data.host)/\($0)" }
        }
    }

    struct ServerRow: Equatable {
        let name: String
        let signedIn: Bool
    }

    /// The Jellyfin rows Settings lists, in order.
    func serverRows() async -> [ServerRow] {
        let store = app.services.serverStore
        let live = Set(await store.sessions.map(\.id))
        return await store.servers.compactMap { server in
            guard case .jellyfin(let data) = server.kind else { return nil }
            return ServerRow(name: data.serverName, signedIn: live.contains(server.id))
        }
    }
}

/// A frame thumbnailer that returns one fixed frame and records every URL it was asked to decode.
@MainActor
final class RecordingThumbnailer: FrameThumbnailing {
    static let frame = ThumbnailFrame(data: Data("frame".utf8), duration: .seconds(42))
    private(set) var requests: [URL] = []

    func frame(from url: URL, at position: Float, timeout: Duration) async throws -> ThumbnailFrame {
        requests.append(url)
        return Self.frame
    }
}

/// Bonjour browsing the scenario drives: `advertise` replaces what the latest browse sees.
private final class ScriptedBonjour: Sendable {
    private let latest = Mutex<AsyncStream<[String]>.Continuation?>(nil)

    func browse() -> AsyncStream<[String]> {
        let (stream, continuation) = AsyncStream<[String]>.makeStream()
        latest.withLock { $0 = continuation }
        return stream
    }

    func advertise(_ serviceNames: [String]) {
        _ = latest.withLock { $0?.yield(serviceNames) }
    }
}

/// Reachability the scenario drives: every subscription starts from the current state, then follows
/// `set`.
private final class ScriptedReachability: ReachabilityMonitoring, Sendable {
    private struct State {
        var isSatisfied = true
        var latest: AsyncStream<ReachabilityState>.Continuation?
    }

    private let state = Mutex(State())

    var pathUpdates: AsyncStream<ReachabilityState> {
        let (stream, continuation) = AsyncStream<ReachabilityState>.makeStream()
        state.withLock {
            $0.latest = continuation
            continuation.yield(ReachabilityState(isSatisfied: $0.isSatisfied, isConstrained: false))
        }
        return stream
    }

    func set(isSatisfied: Bool) {
        state.withLock {
            $0.isSatisfied = isSatisfied
            _ = $0.latest?.yield(ReachabilityState(isSatisfied: isSatisfied, isConstrained: false))
        }
    }
}

private struct SilentAudioSession: AudioSessionControlling {
    func activate() async throws {}
    func deactivate() async {}
}
