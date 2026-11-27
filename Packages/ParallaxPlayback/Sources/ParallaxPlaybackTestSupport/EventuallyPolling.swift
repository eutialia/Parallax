import Foundation
import ParallaxTestPolling
import Testing

/// Waits for a MainActor condition instead of sleeping a margin, and ends the test if it never
/// holds: the lines after it may depend on it.
///
/// Every suite that drives a real engine needs this and each had grown its own copy —
/// `requireEventually` in `AVKitSeekSettleTests`, another in the app's `PlayerViewModelTests` —
/// with different sleep granularities and two different opinions on whether expiry is a
/// failure. It is one helper: expiry IS a failure (a condition that never holds is exactly
/// what a test is asserting against), and the timeout is an anti-hang ceiling, never part of
/// the claim.
///
/// `sourceLocation` defaults to the CALLER's, so a failure points at the assertion rather than
/// at this file.
@MainActor
public func requireEventually(
    _ condition: () -> Bool,
    _ what: Comment,
    timeout: Duration = .seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    try await pollUntil(condition, timeout: timeout)
    try #require(condition(), what, sourceLocation: sourceLocation)
}

/// `requireEventually` without the assertion: waits for `condition` and returns whether it
/// held. For the handful of places that need to STAND somewhere (drive a poll loop far enough
/// to make a following negative assertion a real observation) rather than assert on arrival.
@MainActor
@discardableResult
public func pollUntil(
    _ condition: () -> Bool,
    timeout: Duration = .seconds(5)
) async throws -> Bool {
    try await Ceiling.poll(timeout) { condition() }
}
