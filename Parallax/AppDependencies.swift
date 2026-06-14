import Foundation
import Observation
import ParallaxCore
import ParallaxJellyfin
import ParallaxPlayback

@Observable
@MainActor
final class AppDependencies {
    let serverStore: ServerStore
    let sessionManager: SessionManager
    let deviceIdentityProvider: DeviceIdentityProvider
    let lanDiscovery: LANServerDiscovery
    let jellyfinLibraryRepoFactory: @Sendable (Session) async -> LibraryRepository
    let mediaRepoFactory: @Sendable (LibrarySource) async -> any MediaRepository
    let imagePipelineFactory: ImagePipelineFactory
    let deviceProfileBuilder: DeviceProfileBuilder
    let playbackInfoFactory: @Sendable (Session) async -> PlaybackInfoService
    let playbackEngineFactory: @MainActor @Sendable (PlaybackEngineID) -> any PlaybackEngine
    let audioSession: any AudioSessionControlling

    init(
        serverStore: ServerStore,
        sessionManager: SessionManager,
        deviceIdentityProvider: DeviceIdentityProvider,
        lanDiscovery: LANServerDiscovery,
        jellyfinLibraryRepoFactory: @Sendable @escaping (Session) async -> LibraryRepository,
        mediaRepoFactory: @Sendable @escaping (LibrarySource) async -> any MediaRepository,
        imagePipelineFactory: ImagePipelineFactory,
        deviceProfileBuilder: DeviceProfileBuilder,
        playbackInfoFactory: @Sendable @escaping (Session) async -> PlaybackInfoService,
        playbackEngineFactory: @MainActor @Sendable @escaping (PlaybackEngineID) -> any PlaybackEngine,
        audioSession: any AudioSessionControlling
    ) {
        self.serverStore = serverStore
        self.sessionManager = sessionManager
        self.deviceIdentityProvider = deviceIdentityProvider
        self.lanDiscovery = lanDiscovery
        self.jellyfinLibraryRepoFactory = jellyfinLibraryRepoFactory
        self.mediaRepoFactory = mediaRepoFactory
        self.imagePipelineFactory = imagePipelineFactory
        self.deviceProfileBuilder = deviceProfileBuilder
        self.playbackInfoFactory = playbackInfoFactory
        self.playbackEngineFactory = playbackEngineFactory
        self.audioSession = audioSession
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
        let mediaRepoFactory: @Sendable (LibrarySource) async -> any MediaRepository = { source in
            switch source {
            case .jellyfin(let session): await repoStore.repository(for: session)
            }
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

        return AppDependencies(
            serverStore: store,
            sessionManager: manager,
            deviceIdentityProvider: identity,
            lanDiscovery: LANServerDiscovery(),
            jellyfinLibraryRepoFactory: jellyfinRepoFactory,
            mediaRepoFactory: mediaRepoFactory,
            // Resolve the image-pipeline device identity from the same provider
            // as auth, so image traffic presents the persisted deviceID rather
            // than a per-launch random UUID.
            imagePipelineFactory: ImagePipelineFactory(identityProvider: identity),
            deviceProfileBuilder: profileBuilder,
            playbackInfoFactory: playbackInfoFactory,
            playbackEngineFactory: engineFactory,
            audioSession: audioSession
        )
    }

    private static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        return short
    }
}
