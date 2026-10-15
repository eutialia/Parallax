import AVFoundation
import Foundation
import UIKit
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
        let clock = ContinuousClock()
        return AppEnvironment(
            keychain: Keychain(service: "com.lhdev.parallax"),
            defaults: .standard,
            storageDirectory: .applicationSupportDirectory,
            cachesDirectory: .cachesDirectory,
            urlSessionConfiguration: .default,
            clock: clock,
            reachability: NWPathReachabilityMonitor(),
            capabilityProbe: LiveCapabilityProbe(),
            lanBroadcaster: LANServerDiscovery.broadcast,
            audioSession: LiveAudioSession(),
            smbConnections: .live(clock: clock),
            browseSMBServices: SMBBonjourDiscovery.liveServiceNames,
            // `AVPlayer.eligibleForHDRPlayback` is not KVO-observable; this notification is the
            // supported way to learn it moved.
            hdrEligibilityChanges: {
                AsyncStream { continuation in
                    let relay = Task {
                        for await _ in NotificationCenter.default.notifications(
                            named: AVPlayer.eligibleForHDRPlaybackDidChangeNotification
                        ) {
                            continuation.yield()
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in relay.cancel() }
                }
            },
            thumbnailer: VLCThumbnailer(),
            avThumbnailer: AVThumbnailer(),
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
            deviceName: UIDevice.current.model,
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
