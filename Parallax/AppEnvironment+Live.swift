import Foundation
import ParallaxCore
import ParallaxFeatures
import ParallaxJellyfin
import ParallaxFileBrowse
import ParallaxPlayback
import ParallaxPlaybackVLC

extension AppEnvironment {
    static func live() -> AppEnvironment {
        // The DEBUG-picked startup profile only applies to .avKit — VLCKitEngine has its own
        // buffering knobs and this store never touches it.
        let startupTuningStore = StartupTuningStore()
        return AppEnvironment(
            keychain: Keychain(service: "com.lhdev.parallax"),
            defaults: .standard,
            storageDirectory: .applicationSupportDirectory,
            cachesDirectory: .cachesDirectory,
            urlSessionConfiguration: .default,
            clock: ContinuousClock(),
            reachability: NWPathReachabilityMonitor(),
            capabilityProbe: LiveCapabilityProbe(),
            lanBroadcaster: LANServerDiscovery.broadcast,
            audioSession: LiveAudioSession(),
            smbConnections: .live(),
            browseSMBServices: SMBBonjourDiscovery.liveServiceNames,
            thumbnailer: VLCThumbnailer(),
            // VLC events are configured lazily by VLCKitEngine.init() (idempotent static-once).
            makePlaybackEngine: { id, vlcLibraryOptions in
                switch id {
                case .avKit: AVKitEngine(tuning: startupTuningStore.selected.tuning)
                case .vlcKit: VLCKitEngine(libraryOptions: vlcLibraryOptions)
                }
            },
            makeNowPlaying: { NowPlayingController() },
            prepareDisplay: { engine in
                #if os(tvOS)
                await DisplayCriteriaMatcher.prepare(for: engine)
                #endif
            },
            engineSubtitleFonts: { design in
                EngineSubtitleFonts(
                    directory: VLCSubtitleFonts.directory(for: design),
                    family: VLCSubtitleFonts.freetypeFamily(for: design)
                )
            },
            clientName: "Parallax",
            deviceName: "iOS Device",
            appVersion: AppInfo.shortVersion,
            launchReveal: {
                #if os(tvOS)
                .homeAndLibraries
                #else
                .home
                #endif
            }()
        )
    }
}
