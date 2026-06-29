import Foundation

/// Streams coarse network reachability — `true` when the system reports a satisfied network
/// path, `false` when it doesn't.
///
/// Mirrors `AudioSessionControlling`'s AsyncStream shape so app-wiring code can `for await`
/// over it from a launch-time `Task` and republish it as observable UI state, without this
/// package importing SwiftUI or Combine (the zero-platform-drift contract: logic crosses as
/// `AsyncStream`, the `@Observable` shell lives in the app).
///
/// Emissions are **deduped to transitions**: the stream yields the current state once at
/// subscription, then only when satisfied-ness flips — so a consumer's `onChange` fires on
/// genuine offline↔online edges, not on every interface wobble (Wi-Fi → cellular, etc.).
public protocol ReachabilityMonitoring: Sendable {
    /// `true` = a usable network path exists (`NWPath.status == .satisfied`). The first element
    /// is the current state at subscription; subsequent elements are transitions only.
    var pathUpdates: AsyncStream<Bool> { get }
}
