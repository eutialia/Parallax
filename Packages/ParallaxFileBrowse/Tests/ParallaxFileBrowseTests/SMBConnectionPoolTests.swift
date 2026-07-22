import Foundation
import os
import Testing
@testable import ParallaxFileBrowse

/// A controllable wall clock: `SMBConnectionPool` reads time through an injected `now`, so a test can
/// simulate a slow cold connect and TTL expiry without ever sleeping. Starts at a captured
/// `ContinuousClock` instant and only moves when a test (or the fake connector) advances it.
private final class FakeClock: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: ContinuousClock().now)
    func now() -> ContinuousClock.Instant { state.withLock { $0 } }
    func advance(by duration: Duration) { state.withLock { $0 = $0.advanced(by: duration) } }
}

/// Shared bookkeeping for the fake connector: vends monotonically-ided connections, records which
/// ids were connected and disconnected, and simulates per-host cold-connect latency by advancing the
/// shared clock inside `connect`.
private final class FakeSMBWorld: @unchecked Sendable {
    let clock = FakeClock()
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var nextID = 0
        var connected: [Int] = []
        var disconnected: [Int] = []
        var latencyByHost: [String: Duration] = [:]
    }

    var connectedIDs: [Int] { state.withLock { $0.connected } }
    var disconnectedIDs: [Int] { state.withLock { $0.disconnected } }

    func setLatency(_ duration: Duration, host: String) {
        state.withLock { $0.latencyByHost[host] = duration }
    }

    func recordDisconnect(_ id: Int) {
        state.withLock { $0.disconnected.append(id) }
    }

    /// The connector wired into the pool: assigns a fresh id, records the connect, and advances the
    /// clock by the host's configured latency to simulate the cold-connect wall time the pool times.
    func connect(_ target: SMBConnectionTarget) async throws -> FakeSMBConnection {
        let (id, latency): (Int, Duration) = state.withLock { s in
            let id = s.nextID
            s.nextID += 1
            s.connected.append(id)
            return (id, s.latencyByHost[target.host] ?? .zero)
        }
        clock.advance(by: latency)
        return FakeSMBConnection(id: id, world: self)
    }
}

private struct FakeSMBConnection: PoolableSMBConnection {
    let id: Int
    let world: FakeSMBWorld
    func disconnectGracefully() async { world.recordDisconnect(id) }
}

@Suite("SMBConnectionPool")
struct SMBConnectionPoolTests {

    /// Builds a pool wired to a fresh fake world, with the background sweep pushed far out so only
    /// the opportunistic/explicit reaps under test run.
    private func makePool(
        maxIdlePerKey: Int = 4,
        idleTTL: Duration = .seconds(60)
    ) -> (SMBConnectionPool<FakeSMBConnection>, FakeSMBWorld) {
        let world = FakeSMBWorld()
        let pool = SMBConnectionPool<FakeSMBConnection>(
            connectTimeout: 5,
            maxIdlePerKey: maxIdlePerKey,
            idleTTL: idleTTL,
            sweepInterval: .seconds(3600),
            now: { [clock = world.clock] in clock.now() },
            connect: { try await world.connect($0) }
        )
        return (pool, world)
    }

    private func target(host: String = "host", share: String = "share", password: String = "pw") -> SMBConnectionTarget {
        SMBConnectionTarget(host: host, username: "user", password: password, share: share)
    }

    @Test("a checked-in connection is reused for the same key — no second connect")
    func reusesWarmConnection() async throws {
        let (pool, world) = makePool()
        let t = target()

        let first = try await pool.checkout(t)
        await pool.checkin(first)
        let second = try await pool.checkout(t)

        #expect(world.connectedIDs == [0], "the warm connection must be reused, not reconnected")
        #expect(second.connection.id == 0)
    }

    @Test("a changed password digest keys a fresh connection")
    func passwordDigestKeysFreshConnection() async throws {
        let (pool, world) = makePool()

        let a = try await pool.checkout(target(password: "old"))
        await pool.checkin(a)
        // Same host/user/share, different password → different digest → different key → cold connect.
        let b = try await pool.checkout(target(password: "new"))

        #expect(world.connectedIDs == [0, 1], "a changed credential must not reuse the old session")
        #expect(b.connection.id == 1)
    }

    @Test("idle connections beyond the per-key cap are disconnected on checkin (oldest first)")
    func capEvictsOldestIdle() async throws {
        let (pool, world) = makePool(maxIdlePerKey: 2)
        let t = target()

        // Three simultaneous borrows → three cold connects (nothing idle to reuse).
        let a = try await pool.checkout(t)
        let b = try await pool.checkout(t)
        let c = try await pool.checkout(t)
        #expect(world.connectedIDs == [0, 1, 2])

        await pool.checkin(a)   // idle: [0]
        await pool.checkin(b)   // idle: [0, 1]
        await pool.checkin(c)   // idle: [0, 1, 2] → over cap → evict oldest (0)

        #expect(world.disconnectedIDs == [0], "only the oldest idle connection is evicted")

        // The two survivors are handed back LIFO (warmest first), no new connects.
        let first = try await pool.checkout(t)
        let second = try await pool.checkout(t)
        let reusedIDs: [Int] = [first.connection.id, second.connection.id]
        #expect(reusedIDs == [2, 1])
        #expect(world.connectedIDs == [0, 1, 2], "cap survivors are reused, not reconnected")
    }

    @Test("the reaper disconnects idle connections past the TTL")
    func reapsIdlePastTTL() async throws {
        let (pool, world) = makePool(idleTTL: .seconds(60))
        let t = target()

        let a = try await pool.checkout(t)
        await pool.checkin(a)

        world.clock.advance(by: .seconds(61))
        await pool.reapIdle(asOf: world.clock.now())

        #expect(world.disconnectedIDs == [0], "an idle connection past the TTL must be reaped")
        // Reaped → next checkout is a fresh cold connect.
        _ = try await pool.checkout(t)
        #expect(world.connectedIDs == [0, 1])
    }

    /// The load-bearing invariant: a CHECKED-OUT connection is never disconnected by the reaper, even
    /// when it is well past the TTL — only the idle sibling is torn down. This is the guard against
    /// the libsmb2 use-after-free (76d6fcd) that pooling must never reintroduce.
    @Test("a checked-out connection is never disconnected while borrowed")
    func neverDisconnectsABorrowedConnection() async throws {
        let (pool, world) = makePool(idleTTL: .seconds(60))
        let t = target()

        let borrowed = try await pool.checkout(t)     // conn 0, stays OUT
        let sibling = try await pool.checkout(t)       // conn 1
        await pool.checkin(sibling)                    // conn 1 idle

        world.clock.advance(by: .seconds(120))
        await pool.reapIdle(asOf: world.clock.now())

        #expect(world.disconnectedIDs == [1], "only the idle sibling is reaped")
        #expect(!world.disconnectedIDs.contains(0), "the borrowed connection must never be torn down")

        // The borrower can still return it cleanly afterward.
        await pool.checkin(borrowed)
        #expect(world.disconnectedIDs == [1])
    }

    @Test("linkClass is nil before any cold connect, then reflects cold-connect latency")
    func linkClassReflectsColdLatency() async throws {
        let (pool, world) = makePool()

        #expect(await pool.linkClass(host: "lan") == nil)

        world.setLatency(.milliseconds(50), host: "lan")
        _ = try await pool.checkout(target(host: "lan"))
        #expect(await pool.linkClass(host: "lan") == .lan)

        world.setLatency(.milliseconds(500), host: "wan")
        _ = try await pool.checkout(target(host: "wan"))
        #expect(await pool.linkClass(host: "wan") == .wan)
    }

    @Test("ensureLinkClass probes once (measuring + warming the pool) and skips once known")
    func ensureLinkClassProbesOnceAndWarms() async throws {
        let (pool, world) = makePool()
        let t = target(host: "lan")
        world.setLatency(.milliseconds(50), host: "lan")

        // Unknown host → one probe connect, class measured, connection left idle.
        #expect(await pool.ensureLinkClass(t) == .lan)
        #expect(world.connectedIDs == [0])

        // Known host → no second probe; the warmed connection serves the next checkout.
        #expect(await pool.ensureLinkClass(t) == .lan)
        let reused = try await pool.checkout(t)
        #expect(world.connectedIDs == [0], "the probe's connection must be reused, not reconnected")
        #expect(reused.connection.id == 0)
    }

    @Test("a warm reuse records no new link class; latest cold connect wins")
    func linkClassLatestColdWins() async throws {
        let (pool, world) = makePool()

        world.setLatency(.milliseconds(50), host: "host")
        let a = try await pool.checkout(target(host: "host", share: "one"))
        #expect(await pool.linkClass(host: "host") == .lan)

        // Warm reuse of the same key does no round trips → must not reclassify.
        await pool.checkin(a)
        _ = try await pool.checkout(target(host: "host", share: "one"))
        #expect(await pool.linkClass(host: "host") == .lan)

        // A fresh cold connect to the same host (different share → different key) at high latency
        // reclassifies: latest cold connect wins.
        world.setLatency(.milliseconds(500), host: "host")
        _ = try await pool.checkout(target(host: "host", share: "two"))
        #expect(await pool.linkClass(host: "host") == .wan)
    }
}
