import Foundation
import ParallaxTestScaling
import Testing
@testable import ParallaxFileBrowse

/// Time-limited: nearly every test here waits on a gate or a detached teardown, so a
/// regression that never signals should fail red rather than hang the whole run.
@Suite("SMBConnectionPool", .timeLimit(.minutes(3)))
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

        // The eviction's teardown is detached — checkin decides it synchronously but never waits.
        await untilSettled { world.disconnectedIDs == [0] }
        #expect(world.disconnectedIDs == [0], "only the oldest idle connection is evicted")

        // The two survivors are handed back LIFO (warmest first), no new connects.
        let first = try await pool.checkout(fakeTarget())
        let second = try await pool.checkout(fakeTarget())
        let reusedIDs: [Int] = [first.connection.id, second.connection.id]
        #expect(reusedIDs == [2, 1])
        #expect(world.connectedIDs == [0, 1, 2], "cap survivors are reused, not reconnected")
    }

    // MARK: - Reaping

    @Test("the reaper disconnects idle connections past the TTL, oldest first")
    func reapsIdlePastTTL() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world, idleTTL: .seconds(60))

        // Two idle entries, so the TTL sweep has something to drop without emptying the key.
        let older = try await pool.checkout(fakeTarget())
        let newer = try await pool.checkout(fakeTarget())
        await pool.checkin(older)
        await pool.checkin(newer)

        world.clock.advance(by: .seconds(61))
        await pool.reapIdle(asOf: world.clock.now())
        await untilSettled { world.disconnectedIDs == [0] }

        #expect(world.disconnectedIDs == [0], "the older idle connection past the TTL must be reaped")
        // The survivor is still warm: the next checkout reuses it instead of handshaking.
        let reused = try await pool.checkout(fakeTarget())
        #expect(reused.connection.id == 1)
        #expect(world.connectedIDs == [0, 1], "the surviving warm connection is reused, not reconnected")
    }

    /// The reaper used to age out a key's LAST warm connection, and on a browse wall that was always
    /// the listing's: thumbnail readers hold their borrows for tens of seconds and re-borrow
    /// continuously, so only the listing connection ever sits idle long enough to expire. Every drill
    /// into a subfolder then paid a cold handshake while the pool still held live connections to the
    /// same share.
    @Test("the reaper never drops a key's last warm connection, however long it has been idle")
    func reaperKeepsTheLastWarmConnection() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world, idleTTL: .seconds(60))

        let borrowed = try await pool.checkout(fakeTarget())
        await pool.checkin(borrowed)

        // Far past the TTL, and swept repeatedly — the survivor is not merely granted one grace period.
        world.clock.advance(by: .seconds(3_600))
        await pool.reapIdle(asOf: world.clock.now())
        world.clock.advance(by: .seconds(3_600))
        await pool.reapIdle(asOf: world.clock.now())

        #expect(world.disconnectedIDs.isEmpty, "a key keeps one warm connection indefinitely")
        let reused = try await pool.checkout(fakeTarget())
        #expect(reused.connection.id == 0)
        #expect(world.connectedIDs == [0], "the next drill-in reuses it instead of cold-connecting")
    }

    /// Keeping the last one is per KEY, not per pool: a share whose every connection expired must
    /// still not starve a different share of its survivor.
    @Test("each key keeps its own survivor")
    func eachKeyKeepsItsOwnSurvivor() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world, idleTTL: .seconds(60))

        let media = try await pool.checkout(fakeTarget(share: "Media"))
        let backups = try await pool.checkout(fakeTarget(share: "Backups"))
        await pool.checkin(media)
        await pool.checkin(backups)

        world.clock.advance(by: .seconds(120))
        await pool.reapIdle(asOf: world.clock.now())

        #expect(world.disconnectedIDs.isEmpty)
        #expect(await pool.idleCount == 2, "both keys kept their last connection")
    }

    /// Teardown is round trips on a real NAS, and the reaper runs on somebody's checkout/checkin — so
    /// its disconnects must fan out rather than queue up behind each other.
    @Test("reap disconnects run concurrently, and never on the reaping caller's clock")
    func reapDisconnectsFanOut() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world, idleTTL: .seconds(60))

        // Three idle entries — borrowed simultaneously, or each checkin would just be reused by the
        // next checkout. Two get reaped (the newest survives), so a serialised teardown would be
        // observable as only one arrival at the gate.
        var borrows: [SMBPooledConnection<FakeSMBConnection>] = []
        for _ in 0..<3 { borrows.append(try await pool.checkout(fakeTarget())) }
        for borrowed in borrows { await pool.checkin(borrowed) }
        world.clock.advance(by: .seconds(61))
        await world.teardownGate.close()

        await pool.reapIdle(asOf: world.clock.now())

        // The sweep returned without waiting for a single teardown to finish…
        #expect(world.disconnectedIDs.isEmpty, "the reaper never awaits a teardown")
        // …and both expired connections are tearing down at the same time.
        await untilSettled { await world.teardownGate.arrivalCount == 2 }
        #expect(await world.teardownGate.arrivalCount == 2, "the two teardowns overlap, they don't queue")

        await world.teardownGate.open()
        await untilSettled { world.disconnectedIDs.count == 2 }
        #expect(world.disconnectedIDs.sorted() == [0, 1])
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
        let spare = try await pool.checkout(fakeTarget())      // conn 2
        await pool.checkin(sibling)                            // conn 1 idle
        await pool.checkin(spare)                              // conn 2 idle — the key's survivor

        world.clock.advance(by: .seconds(120))
        await pool.reapIdle(asOf: world.clock.now())
        await untilSettled { world.disconnectedIDs == [1] }

        #expect(world.disconnectedIDs == [1], "only the expired idle sibling is reaped")

        // The borrower can still return it cleanly afterward.
        await pool.checkin(borrowed)
        #expect(world.disconnectedIDs == [1])
    }

    // MARK: - Foreground flush

    /// Opposite of the reaper's survivor rule: after device sleep every idle socket is a corpse, so
    /// `flushIdle` must empty the whole map — every key, no last-warm carve-out.
    @Test("flushIdle empties idle entries across every key and disconnects them all")
    func flushIdleEmptiesEveryKey() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        // Seeded BEFORE the flush so the doc comment's "link-class caches… untouched" promise has
        // something to survive.
        world.setLatency(Self.lanLatency, host: "host")

        let media = try await pool.checkout(fakeTarget(share: "Media"))
        let backups = try await pool.checkout(fakeTarget(share: "Backups"))
        await pool.checkin(media)
        await pool.checkin(backups)

        await pool.flushIdle()
        await untilSettled { world.disconnectedIDs.sorted() == [0, 1] }

        #expect(await pool.idleCount == 0, "flushIdle keeps no per-key survivor")
        #expect(world.disconnectedIDs.sorted() == [0, 1], "every flushed connection is torn down")
        #expect(await pool.condemnedCount == 0, "flushIdle never touches the graveyard")
        #expect(await pool.linkClass(host: "host") == .lan, "the cold-latency link-class cache survives a flush")
    }

    /// Same load-bearing invariant as the reaper: a CHECKED-OUT connection is not in `idle`, so
    /// `flushIdle` must not touch it — the borrower can still check it back in cleanly.
    @Test("flushIdle never disconnects a borrowed connection")
    func flushIdleLeavesBorrowedUntouched() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        // Seeded BEFORE the flush so the doc comment's "link-class caches… untouched" promise has
        // something to survive.
        world.setLatency(Self.lanLatency, host: "host")

        let borrowed = try await pool.checkout(fakeTarget())   // conn 0, stays OUT
        let sibling = try await pool.checkout(fakeTarget())    // conn 1
        let spare = try await pool.checkout(fakeTarget())      // conn 2
        await pool.checkin(sibling)                            // conn 1 idle
        await pool.checkin(spare)                              // conn 2 idle

        await pool.flushIdle()
        await untilSettled { world.disconnectedIDs.sorted() == [1, 2] }

        #expect(world.disconnectedIDs.sorted() == [1, 2], "only idle siblings are flushed")
        #expect(world.disconnectedIDs.contains(0) == false, "the borrowed connection is never disconnected")
        #expect(await pool.condemnedCount == 0, "flushIdle never touches the graveyard")
        #expect(await pool.linkClass(host: "host") == .lan, "the cold-latency link-class cache survives a flush")

        // The FLUSH left it alone; its eventual check-in is where a pre-flush borrow is disposed
        // (see `checkinOfAPreFlushBorrowDisposesIt`) — never pooled back into the emptied map.
        await pool.checkin(borrowed)
        await untilSettled { world.disconnectedIDs.sorted() == [0, 1, 2] }
        #expect(await pool.idleCount == 0)
    }

    /// A borrow taken before the flush is a corpse too — it just wasn't in `idle` to be reaped.
    /// Thumbnail readers hold a borrow for tens of seconds, so a check-in landing after the wake is
    /// the normal case, and pooling it would re-fill the map the flush had just emptied with the
    /// exact dead socket the flush existed to remove.
    @Test("a borrow taken before flushIdle is disposed on checkin, never pooled")
    func checkinOfAPreFlushBorrowDisposesIt() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)

        let preSleep = try await pool.checkout(fakeTarget())   // conn 0, still OUT across the flush
        await pool.flushIdle()

        await pool.checkin(preSleep)
        await untilSettled { world.disconnectedIDs == [0] }

        #expect(await pool.idleCount == 0, "a pre-flush borrow must not re-pollute the idle map")
        #expect(world.disconnectedIDs == [0], "it is disposed with a graceful disconnect")
        #expect(await pool.condemnedCount == 0, "disposal is not a condemn — the call had returned")

        // And the next borrower gets a genuinely fresh connection, not the corpse.
        let fresh = try await pool.checkout(fakeTarget())
        #expect(fresh.connection.id == 1)
    }

    /// The epoch check must only fire for borrows that actually straddle a flush — a borrow taken
    /// afterwards is a live socket and pools normally.
    @Test("a borrow taken after flushIdle checks in normally")
    func checkinOfAPostFlushBorrowIdlesNormally() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)

        await pool.flushIdle()
        let borrowed = try await pool.checkout(fakeTarget())   // conn 0, taken under the new epoch
        await pool.checkin(borrowed)

        #expect(await pool.idleCount == 1, "a post-flush borrow returns to the pool as usual")
        #expect(world.disconnectedIDs.isEmpty, "nothing about it is a corpse")

        // Proven warm: the next checkout reuses it instead of connecting again.
        let reused = try await pool.checkout(fakeTarget())
        #expect(reused.connection.id == 0)
        #expect(world.connectedIDs == [0])
    }

    /// The background sweep exists for a pool that went quiet with connections still warm — nothing
    /// else would reap them, since the opportunistic reaps only run on checkout/checkin.
    @Test("the scheduled sweep reaps a pool that went quiet")
    func scheduledSweepReapsAQuietPool() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world, idleTTL: .seconds(60), sweepInterval: .milliseconds(10))

        let borrowed = try await pool.checkout(fakeTarget())   // starts the sweep task
        let sibling = try await pool.checkout(fakeTarget())
        await pool.checkin(borrowed)
        await pool.checkin(sibling)                            // conn 1 is the key's survivor
        world.clock.advance(by: .seconds(61))

        // No further pool traffic: only the scheduled sweep can tear this down — and it sleeps on a
        // REAL clock, so this waits in real time rather than in scheduler turns. The ceiling is an
        // anti-hang bound, so it scales for oversubscribed CI runners instead of flaking on them —
        // the CI-scaled ceiling (150s) sits above the ~45-100s whole-VM stalls observed on
        // virtualized runners — a stall can only be outlasted, never prevented in-process — while
        // staying under the suite's three-minute time limit so the wait still wins its race.
        let deadline = ContinuousClock().now.advanced(by: CITimeScale.seconds(12.5))
        while world.disconnectedIDs.isEmpty, ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(10))
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

        await untilSettled { world.disconnectedIDs == [0] }
        #expect(world.disconnectedIDs == [0])

        _ = try await pool.checkout(fakeTarget())
        #expect(world.connectedIDs == [0, 1], "a discarded connection must not come back out of the pool")
    }

    // MARK: - Condemn

    /// The pool-level primitive behind every wedged-borrow path: park it, touch nothing while the
    /// call runs, and discard it only when the settlement says the native call has returned. Driven
    /// straight off a settlement here so the parking contract is pinned independently of who
    /// condemned and why.
    @Test("a condemned borrow is parked untouched, then discarded on settle")
    func condemnParksThenDiscardsOnSettle() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let settlement = SMBOperationSettlement()

        let parked = try await condemnFreshBorrow(from: pool, settlement: settlement)

        #expect(await pool.condemnedCount == 1)
        #expect(world.disconnectedIDs.isEmpty, "a pending call means no disconnect, in any mode")
        _ = try await pool.checkout(fakeTarget())
        #expect(world.connectedIDs == [0, 1], "the key cold-connects a replacement; the plot is not reused")

        settlement.markSettled()
        await untilSettled { await pool.releasedTotal == 1 }

        #expect(await pool.condemnedCount == 0)
        #expect(world.disconnectedIDs == [parked], "the settled connection leaves through the discard")
    }

    /// A call that settled while the caller was still deciding must not strand the connection in the
    /// graveyard — the release has to run inline on a condemn that arrives late.
    @Test("condemning an already-settled call releases immediately")
    func condemnAfterSettleReleasesImmediately() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let settlement = SMBOperationSettlement()
        settlement.markSettled()

        let parked = try await condemnFreshBorrow(from: pool, settlement: settlement)

        await untilSettled { await pool.releasedTotal == 1 }
        #expect(await pool.condemnedCount == 0)
        #expect(world.disconnectedIDs == [parked])
    }

    /// The failure exits of a cold connect used to drop whatever the connector had already built,
    /// leaving ARC to run `SMB2Client.deinit` — a disconnect plus a context destroy — on a manager
    /// whose share attach had just failed. The connector now hands its connection over before it
    /// attaches, so every failure exit has something to dispose of properly.
    @Test("a connect that fails after building discards its half-built connection")
    func failedConnectDiscardsTheHalfBuiltConnection() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        // The manager exists and the SHARE ATTACH is what failed — the production shape.
        world.failConnects(with: innerTimeoutError, afterBuilding: true)

        await #expect(throws: POSIXError.self) { _ = try await pool.checkout(fakeTarget()) }

        #expect(world.connectedIDs == [0], "the connection existed before the failure")
        // Claimed off the caller's path, and the connect RETURNED — an ordinary discard.
        await untilSettled { world.disconnectedIDs == [0] }
        #expect(world.disconnectedIDs == [0], "disposed of with a graceful disconnect, not left to ARC")
        #expect(await pool.condemnedTotal == 0, "a returned call never reaches the graveyard")
    }

    /// `requireFresh` exists because the borrower has PROVEN this key's warm connections are dead
    /// (every pooled socket is a corpse after device sleep). Leaving the corpse's idle siblings in
    /// place would just hand the next borrow another one.
    @Test("requireFresh discards the key's idle connections instead of leaving them for the next borrow")
    func requireFreshPurgesTheKeysIdleConnections() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)

        // Two idle connections for the key, plus one for a different key that must not be touched.
        let first = try await pool.checkout(fakeTarget())
        let second = try await pool.checkout(fakeTarget())
        let otherKey = try await pool.checkout(fakeTarget(share: "other"))
        await pool.checkin(first)
        await pool.checkin(second)
        await pool.checkin(otherKey)

        let fresh = try await pool.checkout(fakeTarget(), requireFresh: true)

        #expect(fresh.connection.id == 3, "the borrow is a cold connect, never one of the corpses")
        await untilSettled { world.disconnectedIDs.sorted() == [0, 1] }
        #expect(world.disconnectedIDs.sorted() == [0, 1], "both corpses are torn down")
        #expect(await pool.idleCount == 1, "the other key's connection is untouched")
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

    @Test("a warm reuse records no new link class")
    func warmReuseNeverReclassifies() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)

        world.setLatency(Self.wanLatency, host: "host")
        let borrowed = try await pool.checkout(fakeTarget(host: "host"))
        #expect(await pool.linkClass(host: "host") == .wan)

        // A timed warm reuse would read as a zero-latency sample and promote the host to LAN.
        await pool.checkin(borrowed)
        _ = try await pool.checkout(fakeTarget(host: "host"))
        #expect(world.connectedIDs == [0], "the borrow was a warm reuse")
        #expect(await pool.linkClass(host: "host") == .wan)
    }

    /// Demotion hysteresis. A single slow cold connect is exactly what a post-sleep flush produces
    /// — the radio is still re-associating and the NAS disks are asleep — and once a warm survivor
    /// exists nothing ever re-measures, so one bad sample used to pin a LAN host `.wan` for the rest
    /// of the session (narrowing the thumbnail admission window and disabling the AV backfill).
    @Test("one slow cold sample never demotes a LAN host; two consecutive ones do")
    func lanDemotionNeedsTwoConsecutiveSlowSamples() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)

        world.setLatency(Self.lanLatency, host: "host")
        _ = try await pool.checkout(fakeTarget(host: "host", share: "one"))
        #expect(await pool.linkClass(host: "host") == .lan)

        // Slow → fast → slow: the run is broken each time, so the host stays LAN throughout.
        world.setLatency(Self.wanLatency, host: "host")
        _ = try await pool.checkout(fakeTarget(host: "host", share: "two"))
        #expect(await pool.linkClass(host: "host") == .lan, "a lone slow sample is a blip, not a class")

        world.setLatency(Self.lanLatency, host: "host")
        _ = try await pool.checkout(fakeTarget(host: "host", share: "three"))
        #expect(await pool.linkClass(host: "host") == .lan)

        world.setLatency(Self.wanLatency, host: "host")
        _ = try await pool.checkout(fakeTarget(host: "host", share: "four"))
        #expect(await pool.linkClass(host: "host") == .lan, "the fast sample reset the slow run")

        // Two in a row now: the link really did change.
        _ = try await pool.checkout(fakeTarget(host: "host", share: "five"))
        #expect(await pool.linkClass(host: "host") == .wan)
    }

    /// The reverse direction has no hysteresis: a fast cold connect is proof the host is local, and
    /// nothing about a stale `.wan` label is worth holding against it.
    @Test("a single fast cold sample promotes a WAN host immediately")
    func fastSamplePromotesImmediately() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)

        world.setLatency(Self.wanLatency, host: "host")
        _ = try await pool.checkout(fakeTarget(host: "host", share: "one"))
        #expect(await pool.linkClass(host: "host") == .wan)

        world.setLatency(Self.lanLatency, host: "host")
        _ = try await pool.checkout(fakeTarget(host: "host", share: "two"))
        #expect(await pool.linkClass(host: "host") == .lan)
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

    /// Callers that arrive while a probe is in flight must ride it, not cold-connect alongside it,
    /// and the shared entry must go once that probe ends — a failed one included, or the host stays
    /// stuck on a finished `nil` after the backoff expires.
    @Test("concurrent callers share one in-flight probe, which is cleared even when it fails")
    func concurrentProbesCoalesceAndClear() async {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let target = fakeTarget(host: "dead")
        world.failConnects(with: ConnectFailure())
        await world.connectGate.close()

        await withTaskGroup(of: SMBLinkClass?.self) { group in
            group.addTask { await pool.ensureLinkClass(target) }
            await world.connectGate.awaitArrivals(1)
            for _ in 0..<4 { group.addTask { await pool.ensureLinkClass(target) } }
            for _ in 0..<1_000 { await Task.yield() }
            #expect(await world.connectGate.arrivalCount == 1, "a late caller started its own probe")

            await world.connectGate.open()
            for await linkClass in group { #expect(linkClass == nil) }
        }
        #expect(world.connectAttempts == 1)

        world.clock.advance(by: .seconds(61))
        world.failConnects(with: nil)
        world.setLatency(Self.lanLatency, host: "dead")
        #expect(await pool.ensureLinkClass(target) == .lan, "the failed probe's entry outlived it")
        #expect(world.connectAttempts == 2)
    }

    /// AMSMB2's own timeout doesn't bound every connect phase, so the pool wraps the connector in
    /// `withHardTimeout` and maps the expiry to `SMBListerError.timedOut`. The loser of that race keeps
    /// running — `withHardTimeout` cannot cancel a libsmb2 connect — so it eventually produces a
    /// connection nobody asked for any more. Dropping it let ARC run
    /// `SMB2Client.deinit`, which disconnects and destroys the context; on a connect that is still
    /// pending inside libsmb2 that is the disposal the graveyard exists to forbid. It has to be
    /// handed over instead.
    @Test("a cold connect that lost the hard-timeout race hands its orphan to the graveyard")
    func hardTimeoutOrphanReachesTheGraveyard() async throws {
        let world = FakeSMBWorld()
        let ceiling: TimeInterval = 0.2
        let pool = makeFakePool(
            world: world,
            connectTimeout: ceiling - SMBConnectionPool<FakeSMBConnection>.hardTimeoutGrace
        )
        await world.connectGate.close()

        await #expect(throws: SMBListerError.timedOut) { _ = try await pool.checkout(fakeTarget()) }
        #expect(await pool.condemnedTotal == 0, "nothing exists to park yet — the connector is still hung")

        // The abandoned connector finally finishes, producing a connection with no owner.
        await world.connectGate.open()

        // Its connect call returns right after delivering, so the park ends almost at once — through
        // the graveyard, then the ordinary discard.
        await untilSettled { await pool.releasedTotal == 1 }
        #expect(await pool.condemnedTotal == 1, "the orphan is parked, not dropped for ARC to deinit")
        #expect(await pool.condemnedCount == 0)
        #expect(world.connectedIDs == [0])
        #expect(world.disconnectedIDs == [0], "discarded once its connect had returned")

        _ = try await pool.checkout(fakeTarget())
        #expect(world.connectedIDs == [0, 1], "the orphan never comes back out of the pool")
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
