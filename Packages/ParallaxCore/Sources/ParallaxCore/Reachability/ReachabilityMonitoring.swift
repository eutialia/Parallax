import Foundation

/// A coarse snapshot of the system's network path.
public struct ReachabilityState: Sendable, Equatable {
    /// `true` = a usable network path exists (`NWPath.status == .satisfied`).
    public let isSatisfied: Bool
    /// `true` = the OS reports the path as constrained — the user's Low Data Mode signal
    /// (`NWPath.isConstrained`). Deliberately not `isExpensive`: that flags cellular/hotspot
    /// links the user hasn't asked to throttle, whereas `isConstrained` only flips when Low
    /// Data Mode is actually on.
    public let isConstrained: Bool

    public init(isSatisfied: Bool, isConstrained: Bool) {
        self.isSatisfied = isSatisfied
        self.isConstrained = isConstrained
    }
}

/// Streams coarse network reachability — the current `ReachabilityState` whenever it changes.
///
/// Mirrors `AudioSessionControlling`'s AsyncStream shape so app-wiring code can `for await`
/// over it from a launch-time `Task` and republish it as observable UI state, without this
/// package importing SwiftUI or Combine (the zero-platform-drift contract: logic crosses as
/// `AsyncStream`, the `@Observable` shell lives in the app).
///
/// Emissions are **deduped to transitions**: the stream yields the current state once at
/// subscription, then only when the state actually changes — so a consumer's `onChange` fires
/// on genuine offline↔online or constrained↔unconstrained edges, not on every interface wobble
/// (Wi-Fi → cellular, etc.).
public protocol ReachabilityMonitoring: Sendable {
    /// The first element is the current state at subscription; subsequent elements are
    /// transitions only.
    var pathUpdates: AsyncStream<ReachabilityState> { get }
}
