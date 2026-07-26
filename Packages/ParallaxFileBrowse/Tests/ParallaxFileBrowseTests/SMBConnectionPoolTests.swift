import Foundation
import Testing
@testable import ParallaxFileBrowse

@Suite("SMBConnectionPool")
struct SMBConnectionPoolTests {

    private struct ConnectFailure: Error {}

    /// Latencies are derived from the production threshold, never re-typed: a retune must not
    /// silently invert the classification these tests claim to pin.
    private static let threshold = SMBConnectionPool<FakeSMBConnection>.lanThreshold
    private static let lanLatency = threshold / 2
    private static let wanLatency = threshold * 2

    // MARK: - Reuse and keying

    @Test("a checked-in connection is reused for the same key — no second connect")
    func reusesWarmConnection() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)

        let first = try await pool.checkout(fakeTarget())
        await pool.checkin(first)
        let second = try await pool.checkout(fakeTarget())

        #expect(world.connectedIDs == [0], "the warm connection must be reused, not reconnected")
        #expect(second.connection.id == 0)
    }

    @Test("a changed password digest keys a fresh connection")
    func passwordDigestKeysFreshConnection() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)

        let old = try await pool.checkout(fakeTarget(password: "old"))
        await pool.checkin(old)
        // Same host/user/share, different password → different digest → different key → cold connect.
        let new = try await pool.checkout(fakeTarget(password: "new"))

        #expect(world.connectedIDs == [0, 1], "a changed credential must not reuse the old session")
        #expect(new.connection.id == 1)
    }

    @Test("idle connections beyond the per-key cap are disconnected on checkin (oldest first)")
    func capEvictsOldestIdle() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world, maxIdlePerKey: 2)

        // Three simultaneous borrows → three cold connects (nothing idle to reuse).
        let a = try await pool.checkout(fakeTarget())
        let b = try await pool.checkout(fakeTarget())
        let c = try await pool.checkout(fakeTarget())
        #expect(world.connectedIDs == [0, 1, 2])

        await pool.checkin(a)   // idle: [0]
        await pool.checkin(b)   // idle: [0, 1]
        await pool.checkin(c)   // idle: [0, 1, 2] → over cap → evict oldest (0)

        #expect(world.disconnectedIDs == [0], "only the oldest idle connection is evicted")

        // The two survivors are handed back LIFO (warmest first), no new connects.
        let first = try await pool.checkout(fakeTarget())
        let second = try await pool.checkout(fakeTarget())
        let reusedIDs: [Int] = [first.connection.id, second.connection.id]
        #expect(reusedIDs == [2, 1])
        #expect(world.connectedIDs == [0, 1, 2], "cap survivors are reused, not reconnected")
    }

    // MARK: - Reaping

    @Test("the reaper disconnects idle connections past the TTL")
    func reapsIdlePastTTL() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world, idleTTL: .seconds(60))

        let borrowed = try await pool.checkout(fakeTarget())
        await pool.checkin(borrowed)

        world.clock.advance(by: .seconds(61))
        await pool.reapIdle(asOf: world.clock.now())

        #expect(world.disconnectedIDs == [0], "an idle connection past the TTL must be reaped")
        // Reaped → next checkout is a fresh cold connect.
        _ = try await pool.checkout(fakeTarget())
        #expect(world.connectedIDs == [0, 1])
    }

    /// The load-bearing invariant: a CHECKED-OUT connection is never disconnected by the reaper, even
    /// when it is well past the TTL — only the idle sibling is torn down. This is the guard against
    /// the libsmb2 use-after-free (76d6fcd) that pooling must never reintroduce.
    @Test("a checked-out connection is never disconnected while borrowed")
    func neverDisconnectsABorrowedConnection() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world, idleTTL: .seconds(60))

        let borrowed = try await pool.checkout(fakeTarget())   // conn 0, stays OUT
        let sibling = try await pool.checkout(fakeTarget())    // conn 1
        await pool.checkin(sibling)                            // conn 1 idle

        world.clock.advance(by: .seconds(120))
        await pool.reapIdle(asOf: world.clock.now())

        #expect(world.disconnectedIDs == [1], "only the idle sibling is reaped")

        // The borrower can still return it cleanly afterward.
        await pool.checkin(borrowed)
        #expect(world.disconnectedIDs == [1])
    }

    /// The background sweep exists for a pool that went quiet with connections still warm — nothing
    /// else would reap them, since the opportunistic reaps only run on checkout/checkin.
    @Test("the scheduled sweep reaps a pool that went quiet")
    func scheduledSweepReapsAQuietPool() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world, idleTTL: .seconds(60), sweepInterval: .milliseconds(10))

        let borrowed = try await pool.checkout(fakeTarget())   // starts the sweep task
        await pool.checkin(borrowed)
        world.clock.advance(by: .seconds(61))

        // No further pool traffic: only the scheduled sweep can tear this down.
        var attempts = 0
        while world.disconnectedIDs.isEmpty, attempts < 500 {
            try await Task.sleep(for: .milliseconds(10))
            attempts += 1
        }
        #expect(world.disconnectedIDs == [0])
    }

    // MARK: - Discard

    /// `discard` is the taint path's teardown: fire-and-forget, and deliberately never re-adds the
    /// connection to the idle list.
    @Test("a discarded borrow is disconnected and never reused")
    func discardTearsDownWithoutPooling() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)

        let borrowed = try await pool.checkout(fakeTarget())
        pool.discard(borrowed)

        var attempts = 0
        while world.disconnectedIDs.isEmpty, attempts < 1_000 {
            await Task.yield()
            attempts += 1
        }
        #expect(world.disconnectedIDs == [0])

        _ = try await pool.checkout(fakeTarget())
        #expect(world.connectedIDs == [0, 1], "a discarded connection must not come back out of the pool")
    }

    // MARK: - Link class

    @Test("linkClass is nil before any cold connect, then reflects cold-connect latency")
    func linkClassReflectsColdLatency() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)

        #expect(await pool.linkClass(host: "lan") == nil)

        world.setLatency(Self.lanLatency, host: "lan")
        _ = try await pool.checkout(fakeTarget(host: "lan"))
        #expect(await pool.linkClass(host: "lan") == .lan)

        world.setLatency(Self.wanLatency, host: "wan")
        _ = try await pool.checkout(fakeTarget(host: "wan"))
        #expect(await pool.linkClass(host: "wan") == .wan)
    }

    @Test("ensureLinkClass probes once (measuring + warming the pool) and skips once known")
    func ensureLinkClassProbesOnceAndWarms() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let target = fakeTarget(host: "lan")
        world.setLatency(Self.lanLatency, host: "lan")

        // Unknown host → one probe connect, class measured, connection left idle.
        #expect(await pool.ensureLinkClass(target) == .lan)
        #expect(world.connectedIDs == [0])

        // Known host → no second probe; the warmed connection serves the next checkout.
        #expect(await pool.ensureLinkClass(target) == .lan)
        let reused = try await pool.checkout(target)
        #expect(world.connectedIDs == [0], "the probe's connection must be reused, not reconnected")
        #expect(reused.connection.id == 0)
    }

    @Test("a warm reuse records no new link class; latest cold connect wins")
    func linkClassLatestColdWins() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)

        world.setLatency(Self.lanLatency, host: "host")
        let borrowed = try await pool.checkout(fakeTarget(host: "host", share: "one"))
        #expect(await pool.linkClass(host: "host") == .lan)

        // Warm reuse of the same key does no round trips → must not reclassify.
        await pool.checkin(borrowed)
        _ = try await pool.checkout(fakeTarget(host: "host", share: "one"))
        #expect(await pool.linkClass(host: "host") == .lan)

        // A fresh cold connect to the same host (different share → different key) at high latency
        // reclassifies: latest cold connect wins.
        world.setLatency(Self.wanLatency, host: "host")
        _ = try await pool.checkout(fakeTarget(host: "host", share: "two"))
        #expect(await pool.linkClass(host: "host") == .wan)
    }

    /// A dead host must be re-probed once per backoff window, not once per prefetch batch — without
    /// the memo, a fling through a fresh folder pays a full connect ceiling per batch.
    @Test("a failed probe returns nil and is memoised for the backoff window")
    func failedProbeIsMemoisedForTheBackoff() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let target = fakeTarget(host: "dead")
        world.failConnects(with: ConnectFailure())

        #expect(await pool.ensureLinkClass(target) == nil)
        #expect(world.connectedIDs.isEmpty)
        #expect(world.connectAttempts == 1)

        // Inside the window: answered from the memo, no second connect attempt. Asserted on
        // ATTEMPTS, not `connectedIDs` — a refused connect never becomes a connection, so the
        // success-only ledger reads identically whether or not the memo was consulted.
        #expect(await pool.ensureLinkClass(target) == nil)
        #expect(world.connectAttempts == 1, "the memo must spare a dead host a second connect")

        // Past the window the host is retried — and now succeeds.
        world.clock.advance(by: .seconds(61))
        world.failConnects(with: nil)
        world.setLatency(Self.lanLatency, host: "dead")
        #expect(await pool.ensureLinkClass(target) == .lan)
        #expect(world.connectAttempts == 2, "the window expiring must let exactly one retry through")
        #expect(world.connectedIDs == [0])
    }

    /// AMSMB2's own timeout doesn't bound every connect phase, so the pool wraps the connector in
    /// `withHardTimeout` and maps the expiry to a typed lister error.
    @Test("a connect that outlives the hard ceiling surfaces as SMBListerError.timedOut")
    func hungConnectTimesOut() async throws {
        let world = FakeSMBWorld()
        // The pool's ceiling is `connectTimeout + hardTimeoutGrace`; deriving the nominal value from
        // the grace is what keeps this test sub-second instead of waiting out the real grace period.
        let ceiling: TimeInterval = 0.2
        let pool = makeFakePool(
            world: world,
            connectTimeout: ceiling - SMBConnectionPool<FakeSMBConnection>.hardTimeoutGrace
        )
        await world.connectGate.close()

        await #expect(throws: SMBListerError.timedOut) {
            _ = try await pool.checkout(fakeTarget())
        }

        await world.connectGate.open()
    }

    /// The production specialization (`SMB2Manager`-backed) can't be driven without a share, but its
    /// starting state is what callers key off: an unseen host reads as UNKNOWN, not as `.lan`, so a
    /// prefetch scheduler stays conservative until something has actually measured the link.
    @Test("a fresh production pool reports no link class for any host")
    func productionPoolStartsUnclassified() async {
        #expect(await SMBSharePool().linkClass(host: "nas") == nil)
    }

    // MARK: - Target derivation

    @Test("the connection URL is scheme-only and carries no credentials")
    func targetServerURLHasNoUserinfo() {
        let target = SMBConnectionTarget(host: "Living Room NAS", username: "user", password: "secret",
                                         domain: "WORKGROUP", share: "Media")
        #expect(target.serverURL == SMBURL.hostOnly("Living Room NAS"))
        #expect(target.serverURL.absoluteString.contains("@") == false)
        #expect(target.serverURL.absoluteString.contains("secret") == false)
    }

    /// The domain goes to AMSMB2's dedicated `domain:` parameter, NOT folded into the user field —
    /// libsmb2 maps a `DOMAIN\user` string to the NTLM workstation field instead.
    @Test("the credential carries the bare username and password, never the domain")
    func targetCredentialKeepsTheDomainOut() {
        let target = SMBConnectionTarget(host: "nas", username: "user", password: "secret",
                                         domain: "WORKGROUP", share: "Media")
        #expect(target.credential.user == "user")
        #expect(target.credential.password == "secret")
        #expect(target.credential.persistence == .forSession)
    }

    @Test("the pool key carries a password digest, never the raw secret")
    func targetKeyHashesThePassword() {
        let target = SMBConnectionTarget(host: "nas", username: "user", password: "secret", share: "Media")
        let same = SMBConnectionTarget(host: "nas", username: "user", password: "secret", share: "Media")
        let other = SMBConnectionTarget(host: "nas", username: "user", password: "other", share: "Media")

        #expect(target.key == same.key)
        #expect(target.key != other.key)
        #expect(target.key.passwordDigest != "secret")
    }
}
