import Foundation

/// One SMB-backed HTTP bridge serving session: the `(reader, bridge)` pair plus the
/// ORDER-SENSITIVE teardown both call sites (thumbnail generation, AVKit playback) must
/// never get wrong — stop the bridge FIRST (cancels serve loops, starves zombie clients),
/// THEN disconnect the reader. With the pooled reader, "disconnect the reader" now means
/// "check its borrowed connection back into the pool" — or, if that borrow was tainted or is
/// torn down mid-read, discard it (the pool disconnects it gracefully in the background). Actual
/// libsmb2 context destruction therefore happens only in the pool's reaper on a zero-borrower idle
/// connection (or a background discard drain), which preserves the teardown-under-live-reads guard
/// (76d6fcd) by construction. Inverting the stop order — reader before bridge — would still hand a
/// live serve loop a checked-in/discarded connection, so the order stays load-bearing.
///
/// A passive holder: it doesn't decide *when* teardown happens. The thumbnail path stops
/// it inline at the end of each fetch; the playback path stashes `stop` in the item's
/// cleanup closure and calls it when the player closes.
public struct SMBBridgeSession: Sendable {
    public let reader: SMBRandomAccessReader
    public let bridge: SMBHTTPBridge

    public init(reader: SMBRandomAccessReader, fileName: String, contentType: String) {
        self.reader = reader
        self.bridge = SMBHTTPBridge(reader: reader, fileName: fileName, contentType: contentType)
    }

    /// Starts the bridge and returns the URL to hand the client. On a start failure the
    /// session tears itself down before rethrowing — nothing else will ever own it.
    /// (The reader is lazy, so nothing has touched SMB yet on this path.)
    public func start(scope: SMBHTTPBridge.AddressScope = .lan) async throws -> URL {
        do {
            return try await bridge.start(scope: scope)
        } catch {
            await stop()
            throw error
        }
    }

    /// Ordered teardown — bridge first, reader second. Idempotent. The reader side DRAINS
    /// (bounded) before deciding checkin-vs-disconnect: the bridge's serve loops may still have one
    /// last SMB read in flight when `bridge.stop()` returns (NWConnection cancel doesn't interrupt
    /// an issued libsmb2 read), and both outcomes need the wait — a clean drain lets the warm
    /// connection return to the pool, and a disconnect stays AWAITED so its tail can't overlap the
    /// caller's next fetch (the f4ad8c0 no-overlap tuning).
    public func stop() async {
        await bridge.stop()
        await reader.drainAndDisconnect()
    }

    /// The bridge's session diagnostics (readable after `stop()` too).
    public var stats: SMBHTTPBridge.Stats {
        get async { await bridge.stats }
    }
}
