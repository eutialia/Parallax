import Foundation

/// Per-host AIMD admission window for concurrent SMB thumbnail work.
///
/// Static caps fail when two hosts share one budget (a struggling WAN host starves a fast LAN
/// NAS, or a settable global limit is last-writer-wins under mixed classes). This type tracks ONE
/// host's effective concurrency as a floating window: additive growth on successes, multiplicative
/// shrink on transport faults. The gate owns a dictionary of these keyed by host; this value has
/// no knowledge of other hosts, queues, or content-level decode misses — the caller decides which
/// completions count as "the link kept up" (`.recordSuccess`) vs "the link didn't"
/// (`.recordTransportFailure`). Content failures (undecodable file) are the caller's business and
/// must be reported as successes so a bad file never shrinks a healthy link; completions that
/// moved no bytes (cancellation, cache hits, setup failures) must call NEITHER — zero evidence
/// must not move the window (the gate's `.inconclusive` outcome).
public struct SMBAdmissionWindow: Sendable, Equatable {
    /// SAFETY BOUND, not an operating cap: AIMD picks the operating point and normally sits below
    /// this. It matches the pool's `maxIdlePerKey` of 4 because past that every check-in tears the
    /// excess connection down, so a 5th or 6th permit buys nothing but a cold connect on the next
    /// round — growth beyond 4 costs handshakes instead of saving them.
    private static let ceiling: Double = 4

    private var window: Double

    /// Seeds a starting window from the host's known link class. WAN / unknown start narrow
    /// because 2 concurrent WAN demuxes were measured worse over VPN (2026-07-10: bandwidth
    /// contention, lockstep timeouts each wasting a full 10+ MB download) — that measurement is
    /// the *seed*, not a permanent pin; successes still grow the window when the link keeps up.
    /// LAN starts at 3, matching the pre-AIMD global pool size for a healthy local host.
    public init(seed: SMBLinkClass?) {
        switch seed {
        case .lan:
            window = 3.0
        case .wan, nil:
            window = 1.0
        }
    }

    /// Integer permits this window currently allows. Floors the floating value and never reads as
    /// zero — a host that just halved stays usable for at least one generation.
    public var limit: Int {
        max(1, Int(window.rounded(.down)))
    }

    /// Additive increase using the CURRENT integer limit (before this call): a full window's
    /// worth of successes earns exactly one more integer slot. Narrow windows recover a slot in
    /// fewer successes than wide ones — intentional AIMD behavior so a just-shrunk host ramps
    /// back carefully rather than jumping straight to the old width.
    public mutating func recordSuccess() {
        let step = 1.0 / Double(limit)
        window = min(window + step, Self.ceiling)
    }

    /// Multiplicative decrease — halves the window, floored at 1.0 so a single blip never closes
    /// the host entirely. The next `limit` reflects the floor immediately.
    public mutating func recordTransportFailure() {
        window = max(1.0, window / 2)
    }
}
