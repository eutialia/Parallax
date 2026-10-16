import Foundation
import ParallaxCore
import ParallaxFileBrowse
import ParallaxJellyfin
import ParallaxPlayback
import ParallaxSubtitles

/// The app-scoped service graph, one instance of each, shared by every screen.
public struct AppServices {
    public let settings: SettingsStore
    public let serverStore: ServerStore
    /// Last-known Home feed + library lists on disk, so a launch opens on real content and
    /// revalidates behind it instead of staring at a skeleton. Shared by every cached surface —
    /// one generic store, one directory, one schema version.
    public let snapshots: SnapshotStore
    public let sessionManager: SessionManager
    /// The sign-in transport `sessionManager` runs on, for screens that talk to a server outside a
    /// session (the server-detail reachability probe).
    public let clientFactory: any JellyfinClientFactory
    public let deviceIdentityProvider: DeviceIdentityProvider
    public let lanDiscovery: LANServerDiscovery
    public let jellyfinLibraryRepoFactory: @Sendable (Session) async -> LibraryRepository
    /// Builds the browse repository for a Jellyfin session. SMB no longer flows through a
    /// `MediaRepository`: shares are listed directly via `makeSMBLister` + `SMBFileSource`, so
    /// this is Jellyfin-only.
    public let mediaRepoFactory: @Sendable (Session) async -> any MediaRepository
    /// ONE app-scoped SMB connection pool, shared by the browse listers, the thumbnail provider
    /// and the playback resolver: a browse-then-play flow reuses the same warm authenticated
    /// share connections (and the single cold-connect LAN/WAN classification) instead of
    /// re-handshaking per surface. The pool also OWNS the lifetime of every POOLED share
    /// connection — no browse surface may disconnect one — which is what keeps a listing on a
    /// wedged socket from being freed under its own pending call. (Share ENUMERATION is the
    /// documented exception: it has no share to key on, so `PooledSMBLister.listShares` owns and
    /// gracefully tears down a one-shot connection of its own.)
    public let smbConnections: SMBConnections
    /// Builds a lister for a configured SMB server, reading the password from the Keychain
    /// (slot `token-<id>`). The one place SMB listers are constructed for browsing, so every SMB
    /// surface (folder picker, file browse) shares the same credential read — and the same pooled
    /// share connections, so no browse surface owns a connection lifetime of its own.
    public let makeSMBLister: @Sendable (SMBServerRef) async throws -> any SMBLister
    /// Builds a lister for credentials that are not saved yet — the add-server form, which has to
    /// enumerate shares before anything reaches the Keychain. Takes one `SMBCredentials` value
    /// rather than loose strings: a function type can't carry argument labels, and host/username/
    /// password/domain are all `String`.
    public let makeSMBListerForCredentials: @Sendable (SMBCredentials) -> any SMBLister
    /// Foreground-reactivation hook: flushes dead idle SMB connections after the OS kills every
    /// socket during sleep, so the next browse re-list cold-connects instead of borrowing a corpse.
    public let flushSMBConnections: @Sendable () async -> Void
    public let imagePipelineFactory: ImagePipelineFactory
    public let deviceProfileBuilder: DeviceProfileBuilder
    public let playbackInfoFactory: @Sendable (Session) async -> PlaybackInfoService
    public let playbackEngineFactory: @MainActor @Sendable (PlaybackEngineID, _ vlcLibraryOptions: [String]?) -> any PlaybackEngine
    public let audioSession: any AudioSessionControlling
    let makeNowPlaying: @MainActor @Sendable () -> any NowPlayingUpdating
    let prepareDisplay: @MainActor @Sendable (any PlaybackEngine) async -> Void
    let engineSubtitleFonts: @Sendable (SubtitleFontBundle.Design) -> EngineSubtitleFonts
    /// Sidecar subtitle bytes travel over the same transport as every Jellyfin request.
    let urlSession: URLSession
    let subtitleFetchTimeout: Duration
    public let smbDiscovery: SMBBonjourDiscovery
    /// Local resume positions for SMB playback: no server holds them.
    public let smbResumeStore: SMBResumeStore
    /// Resolves a browsed SMB `Item` into a ready-to-play `SMBPlaybackItem` (decodes the share
    /// path, reads the Keychain password, builds the `smb://` URL + libVLC credential options,
    /// matches sidecar subs). Shares the graph's `ServerStore` so a tapped file resolves its
    /// credentials from the same slot it was browsed under, and the graph's pool so its sidecar
    /// lister and probe/subtitle readers ride the warm connections.
    public let smbPlaybackResolver: SMBPlaybackResolver
    /// Generates + caches frame-grab posters for source-neutral items that carry no server
    /// artwork (SMB). App-scoped so generated thumbnail URLs survive grid teardown/re-entry.
    public let mediaArtworkProvider: MediaArtworkProvider

    /// - Parameter onTokenRejected: every library and playback client reports here when a server
    ///   rejects our access token. The sign-in client is deliberately NOT wired: a 401 while
    ///   signing in is a wrong password, not a dead session.
    init(environment: AppEnvironment, onTokenRejected: @escaping @Sendable (Session) -> Void) {
        // UserDefaults is documented thread-safe; the SDK just doesn't mark it Sendable.
        nonisolated(unsafe) let defaults = environment.defaults
        let settings = SettingsStore(defaults: defaults)
        self.settings = settings
        // The store is handed to `ServerStore` too: removing or invalidating a server is where its
        // cached payloads must be dropped, and that's the one actor both paths go through.
        snapshots = SnapshotStore(container: environment.storageDirectory.appending(
            path: "Snapshots", directoryHint: .isDirectory
        ))
        let store = ServerStore(settings: settings, keychain: environment.keychain, snapshots: snapshots)
        serverStore = store
        let identity = DeviceIdentityProvider(
            client: environment.clientName,
            deviceName: environment.deviceName,
            version: environment.appVersion,
            settings: settings
        )
        deviceIdentityProvider = identity
        let clientFactory = DefaultJellyfinClientFactory(
            identityProvider: identity,
            sessionConfiguration: environment.urlSessionConfiguration,
            clock: environment.clock
        )
        self.clientFactory = clientFactory
        sessionManager = SessionManager(serverStore: store, factory: clientFactory)
        lanDiscovery = LANServerDiscovery(clock: environment.clock, broadcaster: environment.lanBroadcaster)

        // One repo per server, reused across every screen (see LibraryRepositoryStore). Both
        // factories delegate to the same store so there is never more than one LibraryRepository
        // per server alive at once.
        let repoStore = LibraryRepositoryStore(clientFactory: DefaultJellyfinLibraryClientFactory(
            identityProvider: identity,
            onTokenRejected: onTokenRejected,
            sessionConfiguration: environment.urlSessionConfiguration
        ))
        jellyfinLibraryRepoFactory = { session in await repoStore.repository(for: session) }
        mediaRepoFactory = { session in await repoStore.repository(for: session) }

        // One PlaybackInfoService per server, token-keyed — mirrors the LibraryRepositoryStore
        // wiring above.
        let playbackStore = PlaybackInfoServiceStore(
            clientFactory: DefaultJellyfinPlaybackClientFactory(
                identityProvider: identity,
                onTokenRejected: onTokenRejected,
                sessionConfiguration: environment.urlSessionConfiguration
            ),
            clock: environment.clock
        )
        playbackInfoFactory = { session in await playbackStore.service(for: session) }

        let connections = environment.smbConnections
        smbConnections = connections
        // THE single SMB-lister construction site. Everything below routes through it, so every
        // lister in the app shares one pool and one credential shape.
        let makeSMBListerForCredentials = connections.lister
        self.makeSMBListerForCredentials = makeSMBListerForCredentials
        let lifecycle = Log.retained(category: "AppLifecycle")
        flushSMBConnections = {
            lifecycle.mark("→ foreground SMB flush")
            await connections.flushIdle()
            lifecycle.mark("← foreground SMB flush")
        }
        // The password comes through `ServerStore.smbPassword(for:)`, which throws
        // `.auth(.credentialUnavailable)` on a lost Keychain slot instead of degrading to an
        // empty-password logon the server rejects with an error that reads as its fault (the
        // live-NAS EPERM incident).
        makeSMBLister = { ref in
            let password = try await store.smbPassword(for: ref.id)
            return makeSMBListerForCredentials(ref.credentials(password: password))
        }

        // Image traffic presents the persisted deviceID from the same provider as auth, rather
        // than a per-launch random UUID.
        imagePipelineFactory = ImagePipelineFactory(
            identityProvider: identity,
            sessionConfiguration: environment.urlSessionConfiguration,
            cacheDirectory: environment.cachesDirectory
        )
        let profileBuilder = DeviceProfileBuilder(probe: environment.capabilityProbe)
        deviceProfileBuilder = profileBuilder
        playbackEngineFactory = environment.makePlaybackEngine
        audioSession = environment.audioSession
        makeNowPlaying = environment.makeNowPlaying
        prepareDisplay = environment.prepareDisplay
        engineSubtitleFonts = environment.engineSubtitleFonts
        urlSession = URLSession(configuration: environment.urlSessionConfiguration)
        subtitleFetchTimeout = environment.subtitleFetchTimeout

        smbDiscovery = SMBBonjourDiscovery(browse: environment.browseSMBServices)
        let resumeStore = SMBResumeStore(defaults: defaults)
        smbResumeStore = resumeStore
        smbPlaybackResolver = SMBPlaybackResolver(
            serverStore: store, connections: connections, resumeStore: resumeStore, clock: environment.clock,
            deviceProfileBuilder: profileBuilder
        )
        mediaArtworkProvider = MediaArtworkProvider(
            thumbnailer: environment.thumbnailer,
            avThumbnailer: environment.avThumbnailer,
            serverStore: store,
            connections: connections,
            cacheDirectory: environment.cachesDirectory.appending(path: "SMBThumbnails", directoryHint: .isDirectory),
            clock: environment.clock,
            deviceProfileBuilder: profileBuilder
        )
    }
}
