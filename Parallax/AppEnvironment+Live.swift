import AVFoundation
import Foundation
import UIKit
import ParallaxCore
import ParallaxFeatures
import ParallaxJellyfin
import ParallaxFileBrowse
import ParallaxPlayback

extension AppEnvironment {
    static func live() -> AppEnvironment {
        let startupTuningStore = StartupTuningStore()
        let clock = ContinuousClock()
        return AppEnvironment(
            keychain: Keychain(service: "com.lhdev.parallax"),
            defaults: .standard,
            storageDirectory: .applicationSupportDirectory,
            cachesDirectory: .cachesDirectory,
            urlSessionConfiguration: .default,
            clock: clock,
            now: { Date() },
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
            thumbnailer: MediaThumbnailer(),
            makePlaybackEngine: {
                #if os(tvOS)
                AVKitEngine(
                    tuning: startupTuningStore.selected.tuning, clock: clock, prepareDisplay: DisplayCriteriaMatcher.prepare(for:))
                #else
                AVKitEngine(tuning: startupTuningStore.selected.tuning, clock: clock)
                #endif
            },
            makeNowPlaying: { NowPlayingController() },
            clientName: "Parallax",
            deviceName: UIDevice.current.model,
            appVersion: AppInfo.shortVersion,
            launchReveal: {
                #if os(tvOS)
                .homeAndLibraries
                #else
                .home
                #endif
            }(),
            diagnostics: .live
        )
    }
}
