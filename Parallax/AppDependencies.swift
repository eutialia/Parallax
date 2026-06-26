import Foundation
import Observation
import ParallaxCore
import ParallaxFileBrowse
import ParallaxJellyfin
import ParallaxPlayback

@Observable
@MainActor
final class AppDependencies {
    let serverStore: ServerStore
    let sessionManager: SessionManager
    let deviceIdentityProvider: DeviceIdentityProvider
    let lanDiscovery: LANServerDiscovery
    let smbDiscovery: SMBBonjourDiscovery
    let jellyfinLibraryRepoFactory: @Sendable (Session) async -> LibraryRepository
    /// Builds the browse repository for a Jellyfin session. SMB no longer flows through a
    /// `MediaRepository`: shares are listed directly via `makeSMBLister` + `SMBFileSource`, so
    /// this is Jellyfin-only.
    let mediaRepoFactory: @Sendable (Session) async -> any MediaRepository
    /// Builds an `AMSMB2Lister` for a configured SMB server, reading the password from the
    /// Keychain (slot `token-<id>`). The one place SMB listers are constructed for browsing,
    /// so every SMB surface (folder picker, file browse) shares the same credential read.
    let makeSMBLister: @Sendable (SMBServerRef) async -> AMSMB2Lister
    let imagePipelineFactory: ImagePipelineFactory
    let deviceProfileBuilder: DeviceProfileBuilder
    let playbackInfoFactory: @Sendable (Session) async -> PlaybackInfoService
    let playbackEngineFactory: @MainActor @Sendable (PlaybackEngineID) -> any PlaybackEngine
    let audioSession: any AudioSessionControlling
    /// Resolves a browsed SMB `Item` into a ready-to-play `SMBPlaybackItem` (decodes
    /// the share path, reads the Keychain password, builds the `smb://` URL + libVLC
    /// credential options, matches sidecar subs). Owned here so it reaches the player
    /// via the environment with the same `keychain` the live media repos use.
    let smbPlaybackResolver: SMBPlaybackResolver
    /// Generates + caches frame-grab posters for source-neutral items that carry no server
    /// artwork (SMB). App-scoped so generated thumbnail URLs survive grid teardown/re-entry;
    /// shares the same `keychain` as the media repos so it reads passwords from the same slot.
    let mediaArtworkProvider: MediaArtworkProvider

    init(
        serverStore: ServerStore,
        sessionManager: SessionManager,
        deviceIdentityProvider: DeviceIdentityProvider,
        lanDiscovery: LANServerDiscovery,
        smbDiscovery: SMBBonjourDiscovery,
        jellyfinLibraryRepoFactory: @Sendable @escaping (Session) async -> LibraryRepository,
        mediaRepoFactory: @Sendable @escaping (Session) async -> any MediaRepository,
        makeSMBLister: @Sendable @escaping (SMBServerRef) async -> AMSMB2Lister,
        imagePipelineFactory: ImagePipelineFactory,
        deviceProfileBuilder: DeviceProfileBuilder,
        playbackInfoFactory: @Sendable @escaping (Session) async -> PlaybackInfoService,
        playbackEngineFactory: @MainActor @Sendable @escaping (PlaybackEngineID) -> any PlaybackEngine,
        audioSession: any AudioSessionControlling,
        smbPlaybackResolver: SMBPlaybackResolver,
        mediaArtworkProvider: MediaArtworkProvider
    ) {
        self.serverStore = serverStore
        self.sessionManager = sessionManager
        self.deviceIdentityProvider = deviceIdentityProvider
        self.lanDiscovery = lanDiscovery
        self.smbDiscovery = smbDiscovery
        self.jellyfinLibraryRepoFactory = jellyfinLibraryRepoFactory
        self.mediaRepoFactory = mediaRepoFactory
        self.makeSMBLister = makeSMBLister
        self.imagePipelineFactory = imagePipelineFactory
        self.deviceProfileBuilder = deviceProfileBuilder
        self.playbackInfoFactory = playbackInfoFactory
        self.playbackEngineFactory = playbackEngineFactory
        self.audioSession = audioSession
        self.smbPlaybackResolver = smbPlaybackResolver
        self.mediaArtworkProvider = mediaArtworkProvider
    }

    static func live() -> AppDependencies {
        let settings = SettingsStore()
        let keychain = Keychain(service: "com.lhdev.parallax")
        let store = ServerStore(settings: settings, keychain: keychain)
        let identity = DeviceIdentityProvider(
            client: "Parallax",
            deviceName: "iOS Device",
            version: appVersion(),
            settings: settings
        )
        let authFactory = DefaultJellyfinClientFactory(identityProvider: identity)
        let manager = SessionManager(serverStore: store, factory: authFactory)
        let libraryClientFactory = DefaultJellyfinLibraryClientFactory(identityProvider: identity)

        // One repo per server, reused across every screen (see
        // LibraryRepositoryStore). Both factories delegate to the same store so
        // there is never more than one LibraryRepository per server alive at once.
        let repoStore = LibraryRepositoryStore(clientFactory: libraryClientFactory)
        let jellyfinRepoFactory: @Sendable (Session) async -> LibraryRepository = { session in
            await repoStore.repository(for: session)
        }
        let mediaRepoFactory: @Sendable (Session) async -> any MediaRepository = { session in
            await repoStore.repository(for: session)
        }
        // The single SMB-lister construction site, sharing the same Keychain as the repos above so
        // a browsed share reads its password from the slot it was added under. SMB browsing lists
        // shares directly via SMBFileSource — no MediaRepository involved.
        let makeSMBLister: @Sendable (SMBServerRef) async -> AMSMB2Lister = { [keychain] ref in
            let key = KeychainKey<String>(account: ServerStore.tokenAccount(for: ref.id))
            let password = (try? await keychain.read(key)) ?? ""
            return AMSMB2Lister(
                host: ref.data.host,
                username: ref.data.username,
                password: password,
                domain: ref.data.domain
            )
        }

        // Playback wiring. The profile builder probes HDR/audio at runtime via
        // the iOS-only LiveCapabilityProbe; everything else is the fixed
        // AVPlayer whitelist.
        let profileBuilder = DeviceProfileBuilder(probe: LiveCapabilityProbe())

        // One PlaybackInfoService per server, token-keyed — mirrors the
        // LibraryRepositoryStore wiring above. The playback client factory is
        // built exactly like the library one (same identity provider), and the
        // canonical store lives in ParallaxJellyfin (Task 4c.6); the app only
        // delegates to it, never re-implements it.
        let playbackClientFactory = DefaultJellyfinPlaybackClientFactory(identityProvider: identity)
        let playbackStore = PlaybackInfoServiceStore(clientFactory: playbackClientFactory)
        let playbackInfoFactory: @Sendable (Session) async -> PlaybackInfoService = { session in
            await playbackStore.service(for: session)
        }

        // VLC events are configured lazily by VLCKitEngine.init() (idempotent static-once).
        let engineFactory: @MainActor @Sendable (PlaybackEngineID) -> any PlaybackEngine = { id in
            switch id {
            case .avKit:
                return AVKitEngine()
            case .vlcKit:
                return VLCKitEngine()
            }
        }

        let audioSession = LiveAudioSession()

        // One SMB resolver, sharing the same Keychain as the media repos above so a
        // tapped SMB file resolves its credentials from the same slot it was browsed
        // under. Default `makeLister` (the live AMSMB2 sidecar-subtitle lister).
        let smbPlaybackResolver = SMBPlaybackResolver(keychain: keychain)

        // One app-scoped artwork provider. VLCThumbnailer is @MainActor — built here (live() is
        // @MainActor) and handed to the provider actor. Same Keychain as the media repos so it
        // reads SMB passwords from the slot a file was browsed under.
        let mediaArtworkProvider = MediaArtworkProvider(
            thumbnailer: VLCThumbnailer(),
            keychain: keychain
        )

        return AppDependencies(
            serverStore: store,
            sessionManager: manager,
            deviceIdentityProvider: identity,
            lanDiscovery: LANServerDiscovery(),
            smbDiscovery: SMBBonjourDiscovery(),
            jellyfinLibraryRepoFactory: jellyfinRepoFactory,
            mediaRepoFactory: mediaRepoFactory,
            makeSMBLister: makeSMBLister,
            // Resolve the image-pipeline device identity from the same provider
            // as auth, so image traffic presents the persisted deviceID rather
            // than a per-launch random UUID.
            imagePipelineFactory: ImagePipelineFactory(identityProvider: identity),
            deviceProfileBuilder: profileBuilder,
            playbackInfoFactory: playbackInfoFactory,
            playbackEngineFactory: engineFactory,
            audioSession: audioSession,
            smbPlaybackResolver: smbPlaybackResolver,
            mediaArtworkProvider: mediaArtworkProvider
        )
    }

    private static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        return short
    }
}
