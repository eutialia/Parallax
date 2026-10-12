import Foundation
@testable import ParallaxFileBrowse
import ParallaxFileBrowseTestSupport

/// Checks a connection out and condemns it, returning its id.
@discardableResult
func condemnFreshBorrow(
    from pool: SMBConnectionPool<FakeSMBConnection>,
    settlement: SMBOperationSettlement,
    target: SMBConnectionTarget = fakeTarget()
) async throws -> Int {
    let borrowed = try await pool.checkout(target)
    let id = borrowed.connection.id
    await pool.condemn(borrowed, settlement: settlement)
    return id
}

/// AMSMB2's OWN reply timeout, exactly as it reaches our code: a `POSIXError(.ETIMEDOUT)` thrown
/// from its poll loop. The request stays queued inside libsmb2, but the call RETURNED, so every
/// borrow lifecycle discards it like any other completed failure — never the graveyard. Shared so
/// the lister and reader suites test the same error the real one throws.
let innerTimeoutError = POSIXError(.ETIMEDOUT)

/// A target for the fake pool. Defaults are irrelevant to every assertion except the ones that
/// vary a field on purpose (host for link class, password for key derivation).
func fakeTarget(host: String = "host", share: String = "share", password: String = "pw") -> SMBConnectionTarget {
    SMBConnectionTarget(host: host, username: "user", password: password, share: share)
}

/// A lister over `pool`, with share enumeration wired to the same world (it builds its own
/// server-level connection rather than borrowing, exactly as production does).
func makePooledLister(
    world: FakeSMBWorld,
    pool: SMBConnectionPool<FakeSMBConnection>,
    host: String = "nas",
    connectTimeout: TimeInterval = 15
) -> PooledSMBLister<FakeSMBConnection> {
    PooledSMBLister(
        pool: pool,
        credentials: SMBCredentials(host: host, username: "user", password: "pw"),
        connectTimeout: connectTimeout,
        connectServer: { try await world.connect($0, deliver: $1) }
    )
}
