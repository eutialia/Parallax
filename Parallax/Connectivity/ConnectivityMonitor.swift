import Observation
import os
import ParallaxCore
import ParallaxPlayback

/// App-level observable mirror of network reachability. Subscribes to a `ReachabilityMonitoring`
/// stream (the SwiftUI-free package primitive) and republishes the latest satisfied-ness as
/// `isOnline`, so SwiftUI views can react via `@Environment(ConnectivityMonitor.self)` + `onChange`.
///
/// This is the `@Observable` shell around the package's reachability primitive — the same split as
/// `LiveAudioSession` ⇄ `AudioSessionControlling`: the package stays free of SwiftUI/Combine and
/// state crosses as an `AsyncStream`, wrapped here for the view layer.
@Observable
@MainActor
final class ConnectivityMonitor {
    /// `true` until the first path update lands — assume online so a fresh launch doesn't paint an
    /// offline state before the monitor reports. A genuine offline launch flips it to `false` on the
    /// monitor's initial emission (which the package always sends at subscription).
    private(set) var isOnline = true

    private let monitor: any ReachabilityMonitoring

    init(monitor: any ReachabilityMonitoring = NWPathReachabilityMonitor()) {
        self.monitor = monitor
    }

    /// Consume the reachability stream for the app's lifetime. Driven from a `.task` on the app root
    /// (mirrors the `routeChanges` consumer) so it shares the view's cancellation rather than leaking
    /// a free-standing `Task`.
    ///
    /// When `builder` is supplied, satisfied updates also forward the OS's constrained-path
    /// signal (Low Data Mode) into `DeviceProfileBuilder.setNetworkConstrained(_:)`. An
    /// unsatisfied path's constrained bit is meaningless, and skipping it keeps a connectivity
    /// blip from lifting the clamp — every offline stretch necessarily ends with a satisfied
    /// emission carrying the real constraint, so the builder always catches up. The builder
    /// self-dedupes, and only the NEXT `PlaybackInfoService.resolve(...)` picks up the new
    /// profile — in-flight playback is intentionally not interrupted.
    func observe(reportingConstraintTo builder: DeviceProfileBuilder? = nil) async {
        for await state in monitor.pathUpdates {
            // Guarded: Observation's setter fires withMutation even on value-equal writes, and
            // the stream dedupes on the (satisfied, constrained) pair — an unguarded assignment
            // would invalidate every `.recoversFromOffline` reader on constrained-only flips.
            if isOnline != state.isSatisfied { isOnline = state.isSatisfied }
            Log.network.info("Reachability: satisfied=\(state.isSatisfied) constrained=\(state.isConstrained)")
            if state.isSatisfied {
                await builder?.setNetworkConstrained(state.isConstrained)
            }
        }
    }
}
