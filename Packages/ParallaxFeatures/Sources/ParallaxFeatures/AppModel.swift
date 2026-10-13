import Foundation
import Observation
import ParallaxCore
import ParallaxFileBrowse
import ParallaxJellyfin

/// The app's root: the service graph built from an `AppEnvironment`, the state every screen renders,
/// and the app-lifetime flows that keep the two in step. The app builds it on live edges; scenario
/// tests build the same model on fakes.
@Observable
@MainActor
public final class AppModel {
    public let services: AppServices
    public let router = AppRouter()
    public let playback: PlaybackPresenter
    public let launchGate: LaunchGate
    /// App-wide network reachability.
    public let connectivity: ConnectivityMonitor
    /// The scene's activity, forwarded by the app root. Its returns from the background drive
    /// offline recovery and the SMB foreground refresh.
    public let lifecycle = AppLifecycle()
    /// App-wide favorite/played mutations + change broadcast, so every screen showing an item
    /// reflects a toggle made on any other.
    public let userDataActions = UserDataActions()
    /// App-wide subtitle appearance. Read by the player overlay and edited from Settings.
    public let subtitlePreferences: SubtitlePreferences
    /// Home's feed across every signed-in Jellyfin server. nil while none feeds it, which in an
    /// SMB-only setup is for good.
    public internal(set) var home: HomeViewModel?
    /// The library list every navigation root shows.
    public internal(set) var libraries = LibraryList()
    /// Whether what the launch reveal covers has something to show (see `releaseLaunchHold()`).
    /// The tvOS root withholds its tabs until then: its sidebar can only hand focus to content
    /// that has something focusable.
    public internal(set) var isContentReady = false
    /// The reload token whose `loadSources()` pass ran to its end; nil while one is in flight.
    var settledSourcesToken: String?
    /// How many player sessions have stopped, their final reports answered. Moves once per
    /// session, after `runPlayer` closed its model, so a screen re-pulling progress after
    /// watching reads what the server has.
    var endedPlayerSessions = 0
    let clock: any Clock<Duration>
    let recoverableScreens = RecoverableScreens()
    let playbackRefreshScreens = PlaybackRefreshScreens()
    @ObservationIgnored var smbLevels: [WeakLevel] = []

    /// Sessions whose access token the server itself rejected (HTTP 401). A stream rather than a
    /// direct call so the network layer never has to know about the router or the main actor, and
    /// so a burst of simultaneous 401s is handled serially by one consumer instead of racing.
    private let tokenRejections: AsyncStream<Session>
    private let hdrEligibilityChanges: @Sendable () -> AsyncStream<Void>

    let launchReveal: LaunchRevealCoverage

    public init(environment: AppEnvironment) {
        launchReveal = environment.launchReveal
        let (tokenRejections, reportTokenRejected) = AsyncStream<Session>.makeStream()
        self.tokenRejections = tokenRejections
        services = AppServices(environment: environment) { reportTokenRejected.yield($0) }
        playback = PlaybackPresenter(clock: environment.clock)
        launchGate = LaunchGate(
            playsStory: Self.playsLaunchStory(snapshots: services.snapshots, defaults: environment.defaults),
            clock: environment.clock
        )
        connectivity = ConnectivityMonitor(monitor: environment.reachability)
        subtitlePreferences = SubtitlePreferences(store: services.settings)
        clock = environment.clock
        hdrEligibilityChanges = environment.hdrEligibilityChanges
    }

    /// Whether this process plays the launch story at all. The story exists to cover
    /// a boot the user would otherwise sit through; when there's nothing to cover it
    /// becomes a toll, so these launches show content immediately with no stage:
    ///
    /// - a cached Home feed means launch opens onto real content, and
    /// - an SMB-only setup has no server bootstrap at all — shares are browsed on demand.
    ///
    /// Both probes are synchronous (a directory listing and a `UserDefaults` decode — no
    /// Keychain, no network, no actor hop), which is what lets the decision happen before
    /// the first frame. Anything else — first run, a fresh install, a setup whose cache was
    /// dropped — plays the story, as does a post-sign-in `rearm()`.
    private static func playsLaunchStory(snapshots: SnapshotStore, defaults: UserDefaults) -> Bool {
        if snapshots.hasCachedHomeFeed { return false }
        if ServerStore.persistedSetupIsSMBOnly(defaults: defaults) { return false }
        return true
    }

    /// Loads the saved servers and routes off `.bootstrapping`.
    public func bootstrap() async {
        do {
            try await services.serverStore.load()
        } catch {
            Log.persistence.error("ServerStore.load failed: \(error.localizedDescription)")
        }
        await routeToSources()
    }

    /// Signs in with a username and password, then routes onto the signed-in tabs.
    public func signIn(server: URL, username: String, password: String) async throws {
        _ = try await services.sessionManager.signIn(server: server, username: username, password: password)
        await routeToSources()
    }

    /// The flows that live as long as the app does. Never returns; cancel the calling task to stop.
    public func run() async {
        await withDiscardingTaskGroup { group in
            group.addTask { await self.forEachSourceChange { await self.loadSources() } }
            group.addTask { await self.signOutRejectedTokens() }
            group.addTask { await self.refreshAfterPlayback() }
            group.addTask { await self.holdThumbnailsUnderThePlayer() }
            group.addTask { await self.launchGate.releaseStuckHold() }
            group.addTask { await self.recoverStalledScreens() }
            group.addTask { await self.refreshSMBLevelsOnForeground() }
            // Republishes reachability, and forwards the Low Data Mode signal into the device
            // profile builder so the next resolve clamps `maxBitrate`.
            group.addTask { await self.connectivity.observe(reportingConstraintTo: self.services.deviceProfileBuilder) }
            group.addTask { await self.rebuildDeviceProfileOnHDRChange() }
        }
    }

    /// The next resolve builds a fresh device profile whenever HDR eligibility moves. Playback in
    /// flight keeps the profile it started with.
    private func rebuildDeviceProfileOnHDRChange() async {
        for await _ in hdrEligibilityChanges() {
            await services.deviceProfileBuilder.invalidate()
        }
    }

    // MARK: - SMB screens

    public func makeSMBAddServer() -> SMBAddServerModel {
        SMBAddServerModel(
            makeLister: services.makeSMBListerForCredentials,
            serverStore: services.serverStore,
            discovery: services.smbDiscovery,
            lifecycle: lifecycle,
            clock: clock,
            onSaved: { [weak self] in await self?.routeToSources() }
        )
    }

    public func makeSMBBrowse(_ path: SMBBrowsePath) -> SMBBrowseViewModel {
        let level = SMBBrowseViewModel(
            path: path,
            makeLister: services.makeSMBLister,
            artworkProvider: services.mediaArtworkProvider,
            playback: playback
        )
        trackSMBLevel(level)
        return level
    }

    public func makeSMBPasswordRecovery(
        id: ServerID, data: SMBServerData, onRecovered: @escaping () -> Void
    ) -> SMBPasswordRecoveryModel {
        SMBPasswordRecoveryModel(
            id: id,
            data: data,
            makeLister: services.makeSMBListerForCredentials,
            serverStore: services.serverStore,
            clock: clock,
            onRecovered: onRecovered
        )
    }

    public func makeSMBServerSettings(id: ServerID, data: SMBServerData) -> SMBServerSettingsModel {
        SMBServerSettingsModel(
            id: id,
            data: data,
            makeLister: services.makeSMBLister,
            serverStore: services.serverStore,
            router: router,
            routeToSources: { [weak self] in await self?.routeToSources() }
        )
    }

    /// Hands the router one fresh read of the whole source configuration. Every site that changes
    /// which servers exist, or which is signed in, ends here, so the consequences land here too,
    /// in the same turn as the route:
    ///
    /// - Landing on login cuts the launch story and drops what Home and the library list held, so
    ///   the next sign-in starts clean rather than on a previous server's shelves.
    /// - Leaving login for home re-arms the reveal over that first Home boot, the cover a cold
    ///   launch with a saved server gets.
    /// - Another server becoming active closes the reveal again until its Home has settled, so the
    ///   tabs never show over the previous server's reload.
    /// - An open player closes once its own source is gone (see `isLive`). Another server
    ///   becoming active leaves it playing.
    public func routeToSources() async {
        let reading = await services.serverStore.sourceReading
        let before = router.destination
        let activeBefore = router.activeServerID
        router.updateForSources(reading.snapshot)
        switch (before, router.destination) {
        case (_, .login):
            launchGate.finish()
            home = nil
            libraries = LibraryList()
            isContentReady = false
        case (.login, .home):
            launchGate.rearm()
        case (.home, .home) where router.activeServerID != activeBefore:
            isContentReady = false
        case (.bootstrapping, .home), (.home, .home), (_, .bootstrapping):
            break
        }
        if let target = playback.request?.target, !target.isLive(sessions: reading.sessions, servers: reading.servers) {
            playback.dismiss()
        }
    }

    /// Deletes a server's saved row (and its credentials) and re-routes: the source set changed even
    /// when no session did, and the roots' reload token fingerprints every persisted row.
    public func removeServer(_ id: ServerID) async {
        do {
            try await services.serverStore.remove(id)
        } catch {
            Log.persistence.error("removeServer failed for \(id.rawValue): \(error.localizedDescription)")
        }
        await routeToSources()
    }

    /// A server revoked our access token (an admin clearing devices, a server rebuild, the public
    /// demo server's nightly reset). Sign that ONE server out and re-route: the row stays in
    /// Settings as signed-out with a "Sign In Again" prompt, the other servers are untouched, and
    /// `updateForSources` moves the reload token so the sidebar and Home drop its libraries.
    /// Serial by construction: concurrent requests all 401 together, and `invalidateSession`
    /// returns false for every call after the first.
    private func signOutRejectedTokens() async {
        for await rejected in tokenRejections {
            guard await services.serverStore.invalidateSession(rejected) else { continue }
            await routeToSources()
        }
    }

    /// SMB thumbnail generation yields the uplink to the player: the full-screen player covers the
    /// grid WITHOUT cancelling its cells' artwork requests, so without this hold the frame-grab
    /// pipeline keeps streaming over the same link the stream is using. `isPlayerPresent` (not
    /// `request`) so the hold spans the teardown grace too. The loop awaits each edge before the
    /// next, so they reach the provider in order.
    private func holdThumbnailsUnderThePlayer() async {
        let provider = services.mediaArtworkProvider
        for await present in Observations({ self.playback.isPlayerPresent }) {
            await provider.setPlaybackActive(present)
        }
    }
}
