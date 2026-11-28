import Foundation
import ParallaxCore
import ParallaxCoreTestSupport
@testable import ParallaxFeatures
import ParallaxFileBrowse
import ParallaxFileBrowseTestSupport
import ParallaxJellyfin
import ParallaxJellyfinTestSupport
import ParallaxPlayback
import ParallaxPlaybackTestSupport
import ParallaxTestPolling
import Synchronization
import Testing

/// The real `AppModel` on fake edges. Scenarios drive it through the methods the views call and
/// assert on the state the views render.
///
/// Faked: the Keychain, `UserDefaults` (a private suite), the storage and caches directories (a
/// scratch directory), the Jellyfin transport (`FakeJellyfinServer`s), the LAN discovery broadcast,
/// the SMB connections under the real pool (`nas`), Bonjour browsing, the clock, reachability
/// (scripted, online until told otherwise), the display's HDR support and its eligibility changes,
/// what AVPlayer plays, the audio session, the frame thumbnailer, the playback engines
/// (`engines`), Now Playing, the display and the retained diagnostics log (empty, with no network
/// to hand it off over).
@MainActor
final class AppWorld {
    private(set) var app: AppModel
    let clock: TestClock
    /// Every SMB host the app connects to; scenarios script one NAS.
    let nas: FakeSMBWorld
    let thumbnailer: RecordingThumbnailer
    /// Every playback engine the app built, in build order. The last one is playing.
    let engines: EngineLedger
    /// The shared audio session every player activates and deactivates.
    let audioSession: RecordingAudioSession
    private let keychain: FakeKeychain
    private let lan: ScriptedLAN
    private let bonjour: ScriptedBonjour
    private let reachability: ScriptedReachability
    private let display: ScriptedDisplay

    private let environment: AppEnvironment
    /// The servers live as long as the world: their stub hosts route only while they exist.
    private let servers: [FakeJellyfinServer]
    private let suiteName: String
    private let storageDirectory: URL
    private var thumbnailCacheDirectory: URL {
        storageDirectory.appending(path: "Caches/SMBThumbnails", directoryHint: .isDirectory)
    }
    /// A second handle on the app's thumbnail cache, stamping with the world's wall time as the
    /// app's own does.
    func thumbnailCache() -> SMBThumbnailCache {
        SMBThumbnailCache(directory: thumbnailCacheDirectory, now: environment.now)
    }
    /// Leaves for `key` the failure marker builds that grabbed frames through AVFoundation wrote: a
    /// `.fail` beside the thumbnails, named as the cache names the key's files, holding nine
    /// attempts with the last one just now, which those builds backed off for a day.
    func leaveOldRouteFailureMarker(for key: SMBThumbnailKey) throws -> URL {
        let hash = Data("\(key.serverID)\u{0}\(key.share)\u{0}\(key.path)".utf8).sha256Hex
        let mtime = key.modifiedAt.map { String(Int64($0.timeIntervalSince1970.rounded())) } ?? "na"
        let marker = thumbnailCacheDirectory.appending(path: "\(hash)-\(key.size)-\(mtime).fail")
        try FileManager.default.createDirectory(at: thumbnailCacheDirectory, withIntermediateDirectories: true)
        try Data("9\n\(Int64(environment.now().timeIntervalSince1970))".utf8).write(to: marker)
        return marker
    }
    /// Where the world's wall time (`AppEnvironment.now`) starts; the test clock moves it on.
    nonisolated static let wallClockOrigin = Date(timeIntervalSince1970: 1_800_000_000)
    private var lifetime: Task<Void, Never>
    /// The open player, as the player view holds it.
    private(set) var player: PlayerViewModel?
    /// The player view's `.task`, which runs the player's session.
    private var playerSession: Task<Void, Never>?
    /// The `.task`s of the screens on display (see `mount`).
    private var mounted: [Task<Void, Never>] = []

    /// Launches the app the way a cold start does: `run()` and `bootstrap()`, as the app root's
    /// tasks call them. `signedIn` accounts and `savedSMB` servers (with their passwords) were saved
    /// by an earlier launch; `discovering` are the servers that answer a LAN discovery broadcast.
    /// `avPlayer` is what the device's AVPlayer plays. `savedSettings` are settings blobs an
    /// earlier build wrote, by key.
    static func launch(
        signedIn accounts: [(server: FakeJellyfinServer, user: String)] = [],
        savedSMB: [(server: SMBServerData, password: String)] = [],
        savedSettings: [String: Data] = [:],
        discovering lanServers: [FakeJellyfinServer] = [],
        launchReveal: LaunchRevealCoverage = .home,
        avPlayer: AVPlayerSupport = .baseline
    ) async throws -> AppWorld {
        let suiteName = "AppWorld-\(UUID().uuidString)"
        let storageDirectory = URL.temporaryDirectory.appending(path: suiteName, directoryHint: .isDirectory)
        let clock = TestClock()
        let origin = clock.now
        let lan = try ScriptedLAN(lanServers)
        let keychain = FakeKeychain()
        let nas = FakeSMBWorld(clock: clock)
        let bonjour = ScriptedBonjour()
        let thumbnailer = RecordingThumbnailer()
        let engines = EngineLedger()
        let audioSession = RecordingAudioSession()
        let reachability = ScriptedReachability()
        let display = ScriptedDisplay(avPlayer: avPlayer)
        let environment = AppEnvironment(
            keychain: keychain,
            defaults: UserDefaults(suiteName: suiteName)!,
            storageDirectory: storageDirectory,
            cachesDirectory: storageDirectory.appending(path: "Caches", directoryHint: .isDirectory),
            urlSessionConfiguration: StubHTTPTransport.configuration,
            clock: clock,
            // The test clock's run, read as wall time: one time line across a relaunch.
            now: { Self.wallClockOrigin.addingTimeInterval(origin.duration(to: clock.now).fractionalSeconds) },
            reachability: reachability,
            capabilityProbe: display,
            lanBroadcaster: { _ in lan.broadcast() },
            audioSession: audioSession,
            smbConnections: nas.connections(),
            browseSMBServices: { bonjour.browse() },
            hdrEligibilityChanges: { display.eligibilityChanges },
            thumbnailer: thumbnailer,
            makePlaybackEngine: {
                let engine = engines.make()
                engine.landsSeeks = true
                return engine
            },
            makeNowPlaying: { SpyNowPlaying() },
            clientName: "Parallax",
            deviceName: "Scenario Device",
            appVersion: "1.0",
            launchReveal: launchReveal,
            diagnostics: .offline
        )

        savedSettings.forEach { environment.defaults.set($1, forKey: $0) }
        let earlierLaunch = AppModel(environment: environment)
        for account in accounts {
            try await earlierLaunch.services.serverStore.add(account.server.session(signedInAs: account.user))
        }
        for saved in savedSMB {
            try await earlierLaunch.services.serverStore.addSMBServer(saved.server, password: saved.password)
        }

        let world = AppWorld(
            environment: environment, servers: accounts.map(\.server) + lanServers, clock: clock,
            nas: nas, thumbnailer: thumbnailer, engines: engines,
            audioSession: audioSession, keychain: keychain,
            lan: lan, bonjour: bonjour,
            reachability: reachability, display: display,
            suiteName: suiteName, storageDirectory: storageDirectory
        )
        await world.app.bootstrap()
        return world
    }

    private init(
        environment: AppEnvironment, servers: [FakeJellyfinServer], clock: TestClock,
        nas: FakeSMBWorld, thumbnailer: RecordingThumbnailer,
        engines: EngineLedger, audioSession: RecordingAudioSession, keychain: FakeKeychain,
        lan: ScriptedLAN, bonjour: ScriptedBonjour, reachability: ScriptedReachability, display: ScriptedDisplay,
        suiteName: String,
        storageDirectory: URL
    ) {
        let app = AppModel(environment: environment)
        self.app = app
        self.environment = environment
        self.servers = servers
        self.clock = clock
        self.nas = nas
        self.thumbnailer = thumbnailer
        self.engines = engines
        self.audioSession = audioSession
        self.keychain = keychain
        self.lan = lan
        self.bonjour = bonjour
        self.reachability = reachability
        self.display = display
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
        mounted.forEach { $0.cancel() }
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: storageDirectory)
    }

    /// Waits for state the app reaches asynchronously, and ends the scenario at the caller's line
    /// when it never arrives: every later step would run against the wrong state. `condition` is
    /// re-read whenever an observable property it read changes, so it must read observable state;
    /// the deadline is only an anti-hang ceiling.
    func until(_ condition: @escaping @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let arrived = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { await Self.firstHolds(condition) }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                return false
            }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
        guard arrived else { throw StateNeverArrived(awaitedAt: sourceLocation) }
    }

    private static func firstHolds(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        var observed = Observations(condition).makeAsyncIterator()
        while let held = await observed.next() {
            if held { return true }
        }
        return false
    }

    /// `until`, for state behind an actor or in `UserDefaults`, which no observation reaches: it
    /// re-reads `condition` on a 20 ms tick.
    func until(_ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        guard try await Ceiling.poll(.seconds(5), until: condition) else {
            throw StateNeverArrived(awaitedAt: sourceLocation)
        }
    }

    struct StateNeverArrived: Error, CustomStringConvertible {
        let awaitedAt: SourceLocation
        var description: String {
            "the app never reached the state awaited at \(awaitedAt.fileName):\(awaitedAt.line)"
        }
    }

    // MARK: - Steps

    /// Waits until Home's feed and the library list are on screen. The app loads them by itself
    /// whenever the sources change; a scenario that changes them waits for its own visible
    /// difference instead, since this state also holds before the new pass starts.
    func openHome(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await until({
            self.app.isContentReady && !self.app.libraries.isResolving
                && !(self.app.home?.needsNetworkLoad ?? false)
        }, sourceLocation: sourceLocation)
    }

    /// Puts a screen on display: runs its `.task` until the world ends.
    func mount(_ task: @escaping @MainActor () async -> Void) {
        mounted.append(Task { await task() })
    }

    /// Opens `library` from the library list, as tapping its row does: the grid, not yet loaded.
    func openLibrary(_ library: String, on server: FakeJellyfinServer) async throws -> LibraryGridViewModel {
        try await openHome()
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

    /// Lists one film with `contents` behind it on the share, with the files in `beside` next to
    /// it, and taps it, leaving the presenter holding its play request.
    func playSMBFilm(
        named name: String = "Heat.mp4", contents: Data = AppWorld.mp4Bytes, beside siblings: [String: Data] = [:]
    ) async throws {
        let names = [name] + siblings.keys.sorted()
        nas.setFolder(
            names.map { SMBDirectoryEntry(name: $0, isDirectory: false, size: 1, modifiedAt: nil) }, share: "Media")
        nas.setContents(contents)
        siblings.forEach { nas.setContents($1, atPath: $0) }
        let folder = await openSMBFolder(Self.smbRef, share: "Media")
        try await until { !folder.isLoading }
        let title = String(name[..<(name.lastIndex(of: ".") ?? name.endIndex)])
        folder.play(try #require(folder.media.first { $0.displayTitle == title }))
    }

    // MARK: - Player

    /// The engine the player is driving: the last one the app built.
    var engine: FakePlaybackEngine { engines.live }

    /// Mounts the player for the presenter's request, as the root host does, and waits until the
    /// engine it built has been told to play. The host unmounts the player, ending its `.task`,
    /// once the presenter no longer shows that request, whoever dismissed it.
    @discardableResult
    func openPlayer(sourceLocation: SourceLocation = #_sourceLocation) async throws -> PlayerViewModel {
        let built = engines.count
        try mountPlayer(sourceLocation: sourceLocation)
        try await until({ self.engines.count > built && self.engine.calls.contains("play") }, sourceLocation: sourceLocation)
        return try #require(player, sourceLocation: sourceLocation)
    }

    /// Mounts the player as `openPlayer` does, for an open that never reaches an engine, and
    /// waits until it shows its error.
    @discardableResult
    func openPlayerToItsError(sourceLocation: SourceLocation = #_sourceLocation) async throws -> PlayerViewModel {
        try mountPlayer(sourceLocation: sourceLocation)
        try await until({
            if case .failed = self.player?.phase { true } else { false }
        }, sourceLocation: sourceLocation)
        return try #require(player, sourceLocation: sourceLocation)
    }

    private func mountPlayer(sourceLocation: SourceLocation) throws {
        let request = try #require(app.playback.request, "nothing asked the player to open", sourceLocation: sourceLocation)
        let app = app
        let session = Task { [weak self] in
            await app.runPlayer(for: request) { self?.player = $0 }
        }
        playerSession = session
        mount {
            for await shown in Observations({ app.playback.request?.id == request.id }) where !shown {
                session.cancel()
                return
            }
        }
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

    /// The engine fetches every video segment of the film it was handed, as AVPlayer does while
    /// it buffers. Only a film the app delivers through its bridge has segments.
    func engineFetchesTheWholeFilm(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let master = try #require(engine.loadedAssets.last?.url, sourceLocation: sourceLocation)
        let folder = master.deletingLastPathComponent()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let playlist = String(decoding: try await session.data(from: folder.appending(path: "v.m3u8")).0, as: UTF8.self)
        let segments = playlist.split(separator: "\n").filter { $0.hasSuffix(".m4s") }
        try #require(!segments.isEmpty, "\(playlist)", sourceLocation: sourceLocation)
        for segment in segments { _ = try await session.data(from: folder.appending(path: String(segment))) }
    }

    /// The stream played to its end.
    func streamEnds() {
        engine.push(.ended)
    }

    /// The engine can't decode the stream it opened.
    func streamFailsToDecode() {
        engine.push(.failed(.assetNotPlayable))
    }

    /// Closes the player the way the Close chevron does, and waits for its session to end.
    func closePlayer() async {
        await dismissPlayer().value
    }

    /// Closes the player the way the Close chevron does, without waiting: the returned session
    /// ends once the player has stopped.
    func dismissPlayer() -> Task<Void, Never> {
        app.playback.dismiss()
        let session = playerSession ?? Task {}
        playerSession = nil
        player = nil
        return session
    }

    /// The device moves to a display that plays `hdr`, and the system says HDR eligibility changed.
    /// Returns once the app has seen it.
    func connectDisplay(playing hdr: HDRSupport) async throws {
        display.connect(playing: hdr)
        try await until { await self.app.services.deviceProfileBuilder.build().hdr == hdr }
    }

    /// The network drops. Returns once the app has seen it.
    func goOffline() async throws {
        reachability.set(isSatisfied: false)
        try await until { !self.app.connectivity.isOnline }
    }

    /// The network returns. Returns once the app has seen it.
    func comeOnline() async throws {
        reachability.set(isSatisfied: true)
        try await until { self.app.connectivity.isOnline }
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

    /// `server` starts answering LAN discovery broadcasts.
    func lanServerComesUp(_ server: FakeJellyfinServer) throws {
        try lan.comeUp(server)
    }

    /// Bonjour now sees exactly these SMB services on the network.
    func advertiseSMB(_ serviceNames: [String]) {
        bonjour.advertise(serviceNames)
    }

    /// The Bonjour browser fails, as `NWBrowser` does when the network goes away, and ends its
    /// stream.
    func smbBrowseFails() {
        bonjour.fail()
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

/// A thumbnailer that asks the share for each file's size, as the real one's first read does, so
/// the share records the file and a refused file fails here as it would there. It counts the grabs
/// that got that far, fails the first `failingDecodes` of them, and hands back `frame` after that.
@MainActor
final class RecordingThumbnailer: Thumbnailing {
    static let frame = ThumbnailFrame(data: TestFrames.scene, duration: .seconds(42))
    var failingDecodes = 0
    /// Set and close it to park every grab after it has been counted. Left nil it adds no
    /// suspension, which the timing-sensitive scenarios rely on. A grab cancelled while parked
    /// throws `CancellationError` once released, as the real thumbnailer does.
    var hold: AsyncGate?
    private(set) var grabs = 0

    nonisolated func thumbnail(of reader: any RandomAccessReading) async throws -> ThumbnailFrame {
        _ = try await reader.fileSize
        return try await grab()
    }

    private func grab() async throws -> ThumbnailFrame {
        grabs += 1
        await hold?.pass()
        try Task.checkCancellation()
        if failingDecodes > 0 {
            failingDecodes -= 1
            throw UndecodableFrame()
        }
        return Self.frame
    }
}

/// A decode that failed on the file's content, not on the link.
struct UndecodableFrame: Error {}

/// Bonjour browsing the scenario drives: every browse starts from what is advertised, then follows
/// `advertise`.
private final class ScriptedBonjour: Sendable {
    private struct State {
        var advertised: [String] = []
        var latest: AsyncStream<[String]>.Continuation?
    }

    private let state = Mutex(State())

    func browse() -> AsyncStream<[String]> {
        let (stream, continuation) = AsyncStream<[String]>.makeStream()
        state.withLock {
            $0.latest = continuation
            continuation.yield($0.advertised)
        }
        return stream
    }

    func advertise(_ serviceNames: [String]) {
        state.withLock {
            $0.advertised = serviceNames
            _ = $0.latest?.yield(serviceNames)
        }
    }

    func fail() {
        state.withLock {
            $0.latest?.finish()
            $0.latest = nil
        }
    }
}

/// LAN discovery the scenario drives: each broadcast pass hears every server that is up by then.
private final class ScriptedLAN: Sendable {
    private let replies: Mutex<[Data]>

    init(_ servers: [FakeJellyfinServer]) throws {
        replies = Mutex(try servers.map(Self.reply))
    }

    func broadcast() -> [Data] {
        replies.withLock { $0 }
    }

    func comeUp(_ server: FakeJellyfinServer) throws {
        let reply = try Self.reply(server)
        replies.withLock { $0.append(reply) }
    }

    private static func reply(_ server: FakeJellyfinServer) throws -> Data {
        try JSONEncoder().encode(["Address": server.url.absoluteString, "Id": server.id, "Name": server.name])
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

private final class ScriptedDisplay: CapabilityProbe, Sendable {
    private struct State {
        var hdr: HDRSupport = .none
        var latest: AsyncStream<Void>.Continuation?
    }

    private let state = Mutex(State())
    private let avPlayer: AVPlayerSupport

    init(avPlayer: AVPlayerSupport) {
        self.avPlayer = avPlayer
    }

    func hdrSupport() -> HDRSupport { state.withLock { $0.hdr } }

    func avPlayerSupport() -> AVPlayerSupport { avPlayer }

    var eligibilityChanges: AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        state.withLock { $0.latest = continuation }
        return stream
    }

    func connect(playing hdr: HDRSupport) {
        state.withLock {
            $0.hdr = hdr
            _ = $0.latest?.yield()
        }
    }
}

/// An audio session that records every activation and deactivation, in order.
final class RecordingAudioSession: AudioSessionControlling {
    enum Call: Equatable { case activate, deactivate }

    private let log = Mutex<[Call]>([])

    var calls: [Call] { log.withLock { $0 } }

    /// Armed, parks every `activate()` until opened; the call is logged once it lands.
    let activation = ResolveGate()

    func activate() async throws {
        await activation.wait()
        log.withLock { $0.append(.activate) }
    }
    func deactivate() async { log.withLock { $0.append(.deactivate) } }
}

private extension DiagnosticsEdge {
    static let offline = DiagnosticsEdge(
        sessions: { [] },
        isEnabled: { true },
        setEnabled: { _ in },
        clear: {},
        export: { DiagnosticsExportFile(fileName: "diagnostics.txt", payload: Data()) },
        makeHandoffServer: { _ in OfflineHandoffServer() }
    )
}

private struct OfflineHandoffServer: DiagnosticsHandoffServing {
    func start() async throws -> DiagnosticsHandoffServer.Endpoint {
        throw DiagnosticsHandoffServer.HandoffError.offNetwork
    }
    func waitUntilStopped() async {}
    func stop() async {}
}

extension AppWorld {
    nonisolated static let smbServer = SMBServerData(host: "nas.local", username: "ana", domain: "WORKGROUP", shares: ["Media"])
    nonisolated static let smbRef = makeSMBRef(smbServer)
    nonisolated static let mkvBytes = Data([0x1A, 0x45, 0xDF, 0xA3] + Array(repeating: 0, count: 60))
    /// A complete h264/aac MP4: the shape AVPlayer plays directly.
    nonisolated static let mp4Bytes = ISOBMFFFixtures.mp4(traks: [
        ISOBMFFFixtures.trak(stsdEntries: ["avc1"], handler: "vide"),
        ISOBMFFFixtures.trak(stsdEntries: ["mp4a"], handler: "soun"),
    ])
}
