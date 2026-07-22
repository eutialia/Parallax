import Foundation
import Network

/// `ReachabilityMonitoring` backed by `NWPathMonitor`. The `Network` framework is available on
/// both iOS and tvOS with no API divergence, so this lives in the package with **no `#if os`** —
/// the same SwiftUI-free reachability primitive serves every platform (honors the zero-drift rule).
///
/// Dedupes to state transitions and emits the initial state exactly once, so a downstream
/// `onChange` only sees real offline↔online or constrained↔unconstrained edges.
///
/// `@unchecked Sendable`: the only mutable state (`lastState`) is read/written solely inside
/// the `pathUpdateHandler`, which `NWPathMonitor` invokes serially on `monitorQueue` — so there's
/// no concurrent access to protect with a lock.
public final class NWPathReachabilityMonitor: ReachabilityMonitoring, @unchecked Sendable {
    public let pathUpdates: AsyncStream<ReachabilityState>

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.lhdev.parallax.reachability")
    private let continuation: AsyncStream<ReachabilityState>.Continuation
    /// Last forwarded state, mutated only on `monitorQueue` (serial) — drives dedup.
    private var lastState: ReachabilityState?

    public init() {
        let (stream, continuation) = AsyncStream<ReachabilityState>.makeStream()
        self.pathUpdates = stream
        self.continuation = continuation

        monitor.pathUpdateHandler = { [weak self, continuation] path in
            let state = ReachabilityState(
                isSatisfied: path.status == .satisfied,
                isConstrained: path.isConstrained
            )
            // Without `self` the monitor's been torn down (continuation already finished),
            // so the yield is a harmless no-op; with it, forward only genuine transitions.
            guard let self else { continuation.yield(state); return }
            if self.lastState != state {
                self.lastState = state
                continuation.yield(state)
            }
        }
        monitor.start(queue: monitorQueue)
    }

    deinit {
        monitor.cancel()
        continuation.finish()
    }
}
