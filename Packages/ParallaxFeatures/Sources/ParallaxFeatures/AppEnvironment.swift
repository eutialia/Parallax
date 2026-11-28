import Foundation
import ParallaxCore
import ParallaxFileBrowse
import ParallaxPlayback
import ParallaxSubtitles

/// Everything the app reaches outside its own memory: the OS, the network, the disk, time and
/// hardware. `AppModel` builds the whole service graph from this and nothing else, so the app's live
/// edges and a scenario test's fakes run the same graph.
public struct AppEnvironment {
    public let keychain: any KeychainStoring
    /// Backs `SettingsStore`. The launch-story probe reads the same domain synchronously at init.
    public let defaults: UserDefaults
    /// Application Support on device. Snapshots are cached under it.
    public let storageDirectory: URL
    /// Caches on device. Generated SMB thumbnails live under it: the OS may purge them.
    public let cachesDirectory: URL
    /// The transport every Jellyfin client runs on.
    public let urlSessionConfiguration: URLSessionConfiguration
    public let clock: any Clock<Duration>
    /// Wall time, for stamps that outlive the process (a thumbnail's persisted failure marker).
    /// Anything that only measures an interval uses `clock`.
    public let now: @Sendable () -> Date
    public let reachability: any ReachabilityMonitoring
    public let capabilityProbe: any CapabilityProbe
    /// One UDP broadcast pass of Jellyfin's LAN discovery probe, returning the raw replies.
    public let lanBroadcaster: @Sendable (TimeInterval) -> [Data]
    public let audioSession: any AudioSessionControlling
    /// Every SMB connection the app opens, pooled. The pool is real in tests too; only the
    /// connection underneath it is faked.
    public let smbConnections: SMBConnections
    /// One live Bonjour browse for `_smb._tcp`: the complete set of service names on every change,
    /// stopping when the stream's consumer goes away.
    public let browseSMBServices: @Sendable () -> AsyncStream<[String]>
    /// One element each time the device's HDR playback eligibility may have moved: a display
    /// connected or disconnected, Low Power Mode, other system resource shifts.
    public let hdrEligibilityChanges: @Sendable () -> AsyncStream<Void>
    /// A tile's picture of an SMB file: its cover art, or a frame of its video.
    public let thumbnailer: any Thumbnailing
    public let makePlaybackEngine: @MainActor @Sendable () -> any PlaybackEngine
    /// The lock screen and the remote commands, one per player.
    public let makeNowPlaying: @MainActor @Sendable () -> any NowPlayingUpdating
    /// The client identity every Jellyfin request presents.
    public let clientName: String
    public let deviceName: String
    public let appVersion: String
    public let launchReveal: LaunchRevealCoverage
    public let diagnostics: DiagnosticsEdge

    public init(
        keychain: any KeychainStoring,
        defaults: UserDefaults,
        storageDirectory: URL,
        cachesDirectory: URL,
        urlSessionConfiguration: URLSessionConfiguration,
        clock: any Clock<Duration>,
        now: @escaping @Sendable () -> Date,
        reachability: any ReachabilityMonitoring,
        capabilityProbe: any CapabilityProbe,
        lanBroadcaster: @escaping @Sendable (TimeInterval) -> [Data],
        audioSession: any AudioSessionControlling,
        smbConnections: SMBConnections,
        browseSMBServices: @escaping @Sendable () -> AsyncStream<[String]>,
        hdrEligibilityChanges: @escaping @Sendable () -> AsyncStream<Void>,
        thumbnailer: any Thumbnailing,
        makePlaybackEngine: @escaping @MainActor @Sendable () -> any PlaybackEngine,
        makeNowPlaying: @escaping @MainActor @Sendable () -> any NowPlayingUpdating,
        clientName: String,
        deviceName: String,
        appVersion: String,
        launchReveal: LaunchRevealCoverage,
        diagnostics: DiagnosticsEdge
    ) {
        self.keychain = keychain
        self.defaults = defaults
        self.storageDirectory = storageDirectory
        self.cachesDirectory = cachesDirectory
        self.urlSessionConfiguration = urlSessionConfiguration
        self.clock = clock
        self.now = now
        self.reachability = reachability
        self.capabilityProbe = capabilityProbe
        self.lanBroadcaster = lanBroadcaster
        self.audioSession = audioSession
        self.smbConnections = smbConnections
        self.browseSMBServices = browseSMBServices
        self.hdrEligibilityChanges = hdrEligibilityChanges
        self.thumbnailer = thumbnailer
        self.makePlaybackEngine = makePlaybackEngine
        self.makeNowPlaying = makeNowPlaying
        self.clientName = clientName
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.launchReveal = launchReveal
        self.diagnostics = diagnostics
    }
}

/// What the launch reveal opens onto. tvOS shows the library sidebar under the reveal, and its menu
/// can only hand focus to content that has something focusable; iOS reveals onto Home and lets the
/// sidebar fill in behind it.
public enum LaunchRevealCoverage: Sendable {
    case home
    case homeAndLibraries
}
