import AMSMB2
import Foundation

/// The app's one SMB connection pool, behind a face with no connection type in it.
///
/// `SMBConnectionPool`, `PooledSMBLister` and `SMBRandomAccessReader` are generic over the
/// connection so their lifecycle runs against a fake. Their callers outside this package only need
/// listers, readers, the link class and a flush, so the connection type is erased here, once, by
/// the closures the generic `init` captures. Production builds `live()` over `SMB2Manager`; a test
/// builds the same pool over a fake connection and hands it to the same consumers.
public struct SMBConnections: Sendable {
    /// A lister borrowing from the pool for one account.
    public let lister: @Sendable (SMBCredentials) -> any SMBLister
    /// A reader for one file, borrowing from the pool on first use.
    public let reader: @Sendable (_ target: SMBConnectionTarget, _ path: String) -> any SMBShareReading
    /// The host's cold-connect classification, nil until one connect was timed.
    public let linkClass: @Sendable (_ host: String) async -> SMBLinkClass?
    /// `linkClass`, probing with one checkout when the host was never classified.
    public let ensureLinkClass: @Sendable (SMBConnectionTarget) async -> SMBLinkClass?
    /// Drops every idle connection; for the foreground return, when every pooled socket is dead.
    public let flushIdle: @Sendable () async -> Void

    /// - Parameter connectServer: builds the one-shot server-level connection share enumeration
    ///   runs over (see `PooledSMBLister.listShares`).
    public init<Connection: SMBReadableConnection & SMBListableConnection>(
        pool: SMBConnectionPool<Connection>,
        connectServer: @escaping SMBConnectionBuilder<Connection>
    ) {
        self.init(pool: pool) { PooledSMBLister(pool: pool, credentials: $0, connectServer: connectServer) }
    }

    private init<Connection: SMBReadableConnection & SMBListableConnection>(
        pool: SMBConnectionPool<Connection>,
        lister: @escaping @Sendable (SMBCredentials) -> any SMBLister
    ) {
        self.lister = lister
        reader = { target, path in
            SMBRandomAccessReader(
                pool: pool, host: target.host, username: target.username, password: target.password,
                domain: target.domain, share: target.share, path: path
            )
        }
        linkClass = { await pool.linkClass(host: $0) }
        ensureLinkClass = { await pool.ensureLinkClass($0) }
        flushIdle = { await pool.flushIdle() }
    }

    /// Real `SMB2Manager` connections, their hard timeouts waited out on `clock`.
    public static func live(clock: any Clock<Duration>) -> SMBConnections {
        let pool = SMBSharePool(clock: clock)
        return SMBConnections(pool: pool) { PooledSMBLister(pool: pool, credentials: $0) }
    }
}

/// What a file's owner needs from a pooled reader beyond the bridge's reads: the three ways its
/// borrow can end.
public protocol SMBShareReading: SMBBridgeReading {
    /// Checks a clean borrow back in, discards a tainted one, condemns one with a call in flight.
    func disconnect() async
    /// Discards the borrow however cleanly it ends.
    func markUnreusable() async
    /// Fire-and-forget `disconnect()`, returning the transport evidence the borrow gathered first.
    func teardownCapturingTransportFault() async -> Bool
}

extension SMBRandomAccessReader: SMBShareReading {}
