import Foundation

/// One SMB-backed HTTP bridge serving session: the `(reader, bridge)` pair plus the
/// ORDER-SENSITIVE teardown both call sites (thumbnail generation, AVKit playback) must
/// never get wrong — stop the bridge FIRST (cancels serve loops, starves zombie clients),
/// THEN disconnect the reader (graceful drain of in-flight SMB ops). Inverting the order
/// re-opens the libsmb2 teardown-under-live-reads class of bug the reader's graceful
/// disconnect exists to prevent.
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

    /// Ordered teardown — bridge first, reader second. Idempotent.
    public func stop() async {
        await bridge.stop()
        await reader.disconnect()
    }

    /// The bridge's session diagnostics (readable after `stop()` too).
    public var stats: SMBHTTPBridge.Stats {
        get async { await bridge.stats }
    }
}
