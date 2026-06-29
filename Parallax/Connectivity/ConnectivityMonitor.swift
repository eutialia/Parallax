import Observation
import ParallaxCore

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
    func observe() async {
        for await satisfied in monitor.pathUpdates {
            isOnline = satisfied
        }
    }
}
