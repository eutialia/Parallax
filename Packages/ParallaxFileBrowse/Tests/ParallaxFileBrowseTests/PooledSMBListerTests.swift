import Foundation
import Testing
@testable import ParallaxFileBrowse

/// Drives the lister over a fake pooled connection (`FakeSMBConnection`), pinning the borrow
/// lifecycle it replaced a per-screen connection with: warm reuse, the discard-on-failure rule, and
/// the invariant the whole rewrite exists for — a wedged connection is never released while its
/// native call is still pending.
/// Time-limited: most of these tests wait on a gate, a fuse or a detached check-in, so a regression
/// that never signals should fail red rather than hang the whole run.
@Suite("PooledSMBLister", .timeLimit(.minutes(3)))
struct PooledSMBListerTests {

    private struct ListFailure: Error {}
    private struct ShareFailure: Error {}
    private struct ConnectFailure: Error {}

    private static let listing = [
        SMBEntry.dir("Season 1"),
        SMBEntry.file("Film.mkv"),
    ]

    /// A `bounded` ceiling small enough to fire inside a test. The lister races
    /// `connectTimeout + hardTimeoutGrace`, so the nominal timeout has to be derived by SUBTRACTING
    /// the grace — which lands well below zero. Deliberate, and the same trick as
    /// `SMBConnectionPoolTests.hungConnectTimesOut`: `bounded` adds the grace straight back, and
    /// `PooledSMBLister.operationCeiling` clamps at zero so the negative never reaches a real
    /// connection's timeout setter.
    private static let subSecondCeiling: TimeInterval = 0.2
    private static var subSecondNominalTimeout: TimeInterval {
        subSecondCeiling - SMBConnectionPool<FakeSMBConnection>.hardTimeoutGrace
    }

    // MARK: - Warm reuse

    /// The point of pooling the listing path: drilling through folders (or leaving a level and
    /// coming back) must not re-handshake the share.
    @Test("two sequential listings ride ONE warm connection — no second cold connect")
    func sequentialListingsReuseOneConnection() async throws {
        let world = FakeSMBWorld()
        world.setListingOutcome(.entries(Self.listing))
        let pool = makeFakePool(world: world)
        let lister = makePooledLister(world: world, pool: pool)

        let first = try await lister.list(share: "Media", path: "Movies")
        // The borrow is checked in off the caller's path now, so reuse needs it to have LANDED —
        // waiting for that here is what keeps this a test about keying rather than about scheduling.
        await untilSettled { await pool.idleCount == 1 }
        let second = try await lister.list(share: "Media", path: "Movies/Extras")

        #expect(first == Self.listing)
        #expect(second == Self.listing)
        #expect(world.connectAttempts == 1, "the second listing reused the warm connection")
        #expect(world.disconnectedIDs.isEmpty, "a clean borrow goes back to the pool, never torn down")
        #expect(world.listedPaths == ["Movies", "Movies/Extras"])
    }

    @Test("an empty path lists the share root")
    func emptyPathListsRoot() async throws {
        let world = FakeSMBWorld()
        let lister = makePooledLister(world: world, pool: makeFakePool(world: world))

        _ = try await lister.list(share: "Media", path: "")

        #expect(world.listedPaths == ["/"])
    }

    /// Warm reuse is exactly where this matters: the connection arrives carrying the PREVIOUS
    /// borrower's ceiling, so a borrow that doesn't re-assert its own silently inherits a stranger's
    /// (or, on a cold `SMB2Manager`, AMSMB2's 60s default). Two listers over one pool, so the second
    /// borrow is guaranteed warm.
    @Test("every borrow re-pins its own ceiling, including a warm one inheriting another's")
    func everyBorrowRePinsItsOwnOperationTimeout() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let patient = makePooledLister(world: world, pool: pool, connectTimeout: 7)
        let impatient = makePooledLister(world: world, pool: pool, connectTimeout: 3)

        _ = try await patient.list(share: "Media", path: "")
        await untilSettled { await pool.idleCount == 1 }
        _ = try await impatient.list(share: "Media", path: "")

        #expect(world.connectAttempts == 1, "the second borrow must be a warm reuse for this to mean anything")
        #expect(world.timeoutsSet == [7, 3], "the warm borrow overwrote the ceiling it inherited")
    }

    /// The pool keys on share, so two shares of one server are two connections — a listing must not
    /// be served by a connection attached to the wrong tree.
    @Test("switching share takes a different pool key, and switching back reuses the first")
    func shareSwitchTakesADistinctKey() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let lister = makePooledLister(world: world, pool: pool)

        _ = try await lister.list(share: "Media", path: "")
        await untilSettled { await pool.idleCount == 1 }
        _ = try await lister.list(share: "Backups", path: "")
        await untilSettled { await pool.idleCount == 2 }
        _ = try await lister.list(share: "Media", path: "")

        #expect(world.connectedIDs == [0, 1], "the second share cold-connects; the third call is a reuse")
    }

    // MARK: - Teardown is never on the folder-open path

    /// The measured regression this fixes: opening a subfolder awaited the check-in, and the check-in
    /// head-ran the reaper, which disconnected expired connections one after another — so the user's
    /// folder waited on a tree-disconnect + logoff per reaped connection before a single entry
    /// appeared. Entries must arrive while those teardowns are still in flight.
    @Test("a listing returns its entries without waiting for pool teardown, which fans out behind it")
    func listingNeverWaitsForPoolTeardown() async throws {
        let world = FakeSMBWorld()
        world.setListingOutcome(.entries(Self.listing))
        let pool = makeFakePool(world: world, idleTTL: .seconds(60))
        let lister = makePooledLister(world: world, pool: pool)

        // Three warm connections for the listing's key, all aged past the TTL: the sweep this listing
        // triggers reaps two of them (the newest survives and serves the listing itself). Borrowed
        // simultaneously, or each checkin would simply be reused by the next checkout.
        var borrows: [SMBPooledConnection<FakeSMBConnection>] = []
        for _ in 0..<3 { borrows.append(try await pool.checkout(fakeTarget(host: "nas", share: "Media"))) }
        for borrowed in borrows { await pool.checkin(borrowed) }
        world.clock.advance(by: .seconds(61))
        await world.teardownGate.close()

        let entries = try await lister.list(share: "Media", path: "Movies")

        #expect(entries == Self.listing)
        #expect(world.disconnectedIDs.isEmpty, "the folder opened while every teardown was still stuck")
        #expect(world.connectAttempts == 3, "and it opened on a warm connection — no handshake")
        // Both reaped connections are mid-teardown at once, not queued behind each other.
        await untilSettled { await world.teardownGate.arrivalCount == 2 }
        #expect(await world.teardownGate.arrivalCount == 2)

        await world.teardownGate.open()
        await untilSettled { world.disconnectedIDs.count == 2 }
        #expect(world.disconnectedIDs.sorted() == [0, 1])
        #expect(world.useAfterFreeIDs.isEmpty)
    }

    // MARK: - The discard rule (a listing that FINISHED badly)

    @Test("a listing that threw discards the borrow — it is never handed to the next caller")
    func thrownListingDiscardsTheBorrow() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let lister = makePooledLister(world: world, pool: pool)
        world.setListingOutcome(.fails(ListFailure()))

        await #expect(throws: ListFailure.self) {
            _ = try await lister.list(share: "Media", path: "")
        }
        await untilSettled { world.disconnectedIDs == [0] }

        #expect(world.disconnectedIDs == [0], "the suspect socket is disconnected, not pooled")
        #expect(
            await pool.condemnedCount == 0,
            "the call RETURNED (the server said no) — the proven discard path owns this, not the graveyard"
        )
        #expect(world.tornDownWithPendingOps.isEmpty, "nothing was pending when it was torn down")
        _ = try await pool.checkout(fakeTarget(host: "nas", share: "Media"))
        #expect(world.connectedIDs == [0, 1], "nothing idle was left to reuse — the next borrow is cold")
    }

    // MARK: - The one retry (a warm borrow that turned out to be a corpse)

    /// What a failure ON A WARM BORROW gets, as one matrix — the three verdicts differ only in what
    /// the error says about the socket, so they belong side by side:
    ///  - a TRANSPORT failure is the after-sleep case, and the reason a key may keep a warm
    ///    connection forever: every pooled socket is dead on wake and the pool cannot tell, so the
    ///    first folder opened is handed a corpse. Retried on a guaranteed-fresh connection rather
    ///    than putting an error scrim in front of a user whose server is perfectly reachable;
    ///  - an AUTH failure is a real answer from the server — the connection worked well enough to be
    ///    refused on. Retrying wastes a handshake and can lock an account out;
    ///  - AMSMB2's own REPLY TIMEOUT leaves a request queued inside libsmb2, so the borrow is
    ///    condemned and a retry over the same key would be racing that pending call.
    struct WarmBorrowFailure: Sendable, CustomTestStringConvertible {
        let label: String
        let error: any Error & Sendable
        /// Whether the listing is re-attempted on a guaranteed-fresh connection.
        let retries: Bool
        /// Whether the borrow is parked instead of disposed of (libsmb2 still owns a request).
        let condemns: Bool

        var testDescription: String { label }
    }

    static let warmBorrowFailures: [WarmBorrowFailure] = [
        .init(label: "transport failure", error: POSIXError(.ECONNRESET), retries: true, condemns: false),
        // EPERM is libsmb2's credential refusal — see `SMBFileSource.classify`.
        .init(label: "auth failure", error: POSIXError(.EPERM), retries: false, condemns: false),
        .init(label: "reply timeout", error: innerTimeoutError, retries: false, condemns: true),
    ]

    @Test("what a failure on a warm borrow gets: a fresh retry, a surfaced answer, or the graveyard",
          arguments: warmBorrowFailures)
    func warmBorrowFailureRouting(_ scenario: WarmBorrowFailure) async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let lister = makePooledLister(world: world, pool: pool)
        // Listing 1 warms the pool; listing 2 is handed that warm borrow and fails on it; the third
        // scripted outcome only ever runs for the case that earns a retry.
        world.setListingScript([
            .entries(Self.listing),
            .fails(scenario.error),
            .entries(Self.listing),
        ])

        _ = try await lister.list(share: "Media", path: "")
        await untilSettled { await pool.idleCount == 1 }

        if scenario.retries {
            let afterWake = try await lister.list(share: "Media", path: "Movies")
            #expect(afterWake == Self.listing, "the user sees the folder, not a transport error")
            #expect(world.listedPaths == ["/", "Movies", "Movies"], "the same level is listed again")
            #expect(world.connectAttempts == 2, "exactly one extra checkout — the retry cold-connected")
        } else {
            await #expect(throws: POSIXError.self) { _ = try await lister.list(share: "Media", path: "Movies") }
            #expect(world.listedPaths == ["/", "Movies"], "the failure is the answer — no second attempt")
            #expect(world.connectAttempts == 1, "nothing was re-attempted, so nothing reconnected")
        }

        if scenario.condemns {
            #expect(await pool.condemnedCount == 1, "the queued request parks the connection")
            #expect(world.disconnectedIDs.isEmpty, "a discard here would disconnect over a live request")
            // Leave no fuse burning behind the test — it is armed on the fake timer either way.
            await world.fuse.awaitRequests(1)
            await world.fuse.fire()
            await untilSettled { await pool.condemnedCount == 0 }
        } else {
            await untilSettled { world.disconnectedIDs == [0] }
            #expect(world.disconnectedIDs == [0], "the borrow that failed is disposed of, never pooled")
            #expect(await pool.condemnedCount == 0, "a returned call belongs to discard, not the graveyard")
        }
    }

    /// The retry is strictly one, and strictly about the pool having handed out a corpse. A FRESH
    /// connection that fails means the server really is unreachable — retrying it just makes the user
    /// wait through a second ceiling for the same answer.
    @Test("a transport failure on a fresh connection is never retried")
    func freshConnectionFailureIsNotRetried() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let lister = makePooledLister(world: world, pool: pool)
        world.setListingOutcome(.fails(POSIXError(.ECONNRESET)))

        await #expect(throws: POSIXError.self) { _ = try await lister.list(share: "Media", path: "") }

        #expect(world.connectAttempts == 1, "no second connection was ever built")
        #expect(world.listedPaths == ["/"], "and the listing was attempted exactly once")
    }

    /// …and a second failure on the retry is the answer, not a third attempt. The two failures are
    /// deliberately DISTINGUISHABLE: what surfaces has to be the retry's own error, not the original
    /// one held over from the borrow that started this.
    @Test("a retry that fails too surfaces its own error, without a third attempt")
    func retryFailureSurfaces() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let lister = makePooledLister(world: world, pool: pool)
        world.setListingScript([
            .entries(Self.listing),
            .fails(POSIXError(.ECONNRESET)),   // the warm corpse
            .fails(POSIXError(.ENETDOWN)),     // the fresh retry's own failure
        ])

        _ = try await lister.list(share: "Media", path: "")
        await untilSettled { await pool.idleCount == 1 }
        let surfaced = await #expect(throws: POSIXError.self) {
            _ = try await lister.list(share: "Media", path: "")
        }

        #expect(surfaced?.code == .ENETDOWN, "the retry's answer surfaces, not the borrow that caused it")
        #expect(world.connectAttempts == 2, "one warm attempt, one fresh retry, and no more")
        #expect(world.listedPaths == ["/", "/", "/"])
    }

    // MARK: - Connect failures

    /// A checkout that never produced a borrow is not a borrow failure: there is no warm connection
    /// to blame, so there is nothing a fresh retry could tell the user that this attempt didn't.
    @Test("a connect failure surfaces as-is and is never retried")
    func connectFailureSurfacesWithoutARetry() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let lister = makePooledLister(world: world, pool: pool)
        world.failConnects(with: ConnectFailure())

        await #expect(throws: ConnectFailure.self) { _ = try await lister.list(share: "Media", path: "") }

        #expect(world.connectAttempts == 1, "the failure is the answer — no second connection was built")
        #expect(world.listedPaths.isEmpty, "nothing was ever listed")
    }

    /// The regression test for the ownership hole: the connector builds its manager and only THEN
    /// attaches the share, so an attach that hits AMSMB2's reply timeout leaves a live connection
    /// with a request still queued in libsmb2. Dropping it there let ARC run `SMB2Client.deinit` —
    /// a disconnect plus a context destroy — over that pending request.
    @Test("a share attach that times out condemns the manager the connector had already built")
    func connectTimeoutCondemnsTheHalfBuiltConnection() async throws {
        let world = FakeSMBWorld()
        let ceiling: TimeInterval = 9
        let pool = makeFakePool(world: world, connectTimeout: ceiling)
        let lister = makePooledLister(world: world, pool: pool)
        world.failConnects(with: innerTimeoutError, afterBuilding: true)

        await #expect(throws: POSIXError.self) { _ = try await lister.list(share: "Media", path: "") }

        #expect(world.connectedIDs == [0], "the manager existed before the attach failed")
        // Claimed off the caller's path, so the park lands a turn later than the throw.
        await untilSettled { await pool.condemnedCount == 1 }
        #expect(await pool.condemnedCount == 1, "…and it is parked, not dropped for ARC to deinit")
        #expect(world.disconnectedIDs.isEmpty)
        #expect(world.releasedIDs.isEmpty, "a queued request means the reference is held, not let go")

        // Nothing can ever settle this receipt, so a fuse — sized off the ceiling the connect ran
        // under — is what ends the park.
        await world.fuse.awaitRequests(1)
        #expect(await world.fuse.requested == [SMBAbandonedCall.releaseFuse(afterOperationTimeout: ceiling)])
        await world.fuse.fire()
        await untilSettled { world.releasedIDs == [0] }
        #expect(world.disconnectedIDs.isEmpty, "…and it still speaks no SMB on the way out")
    }

    /// Share enumeration builds its own connection outside the pool, so the same half-built failure
    /// reaches it by a different route — and it is the one call that could strand a connection
    /// outright, since nothing else holds a reference to one it never returned.
    @Test("a share enumeration whose connect times out condemns its half-built connection too")
    func listSharesConnectTimeoutCondemnsTheHalfBuiltConnection() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let lister = makePooledLister(world: world, pool: pool)
        world.failConnects(with: innerTimeoutError, afterBuilding: true)

        await #expect(throws: POSIXError.self) { _ = try await lister.listShares() }

        #expect(world.connectedIDs == [0])
        await untilSettled { await pool.condemnedCount == 1 }
        #expect(await pool.condemnedCount == 1, "the one-shot connection is parked, not stranded")
        #expect(world.disconnectedIDs.isEmpty)

        await world.fuse.awaitRequests(1)
        await world.fuse.fire()
        await untilSettled { world.releasedIDs == [0] }
        #expect(world.disconnectedIDs.isEmpty)
    }

    // MARK: - The condemn rule (a listing still RUNNING)

    /// THE regression test for the crash this rewrite fixes: a listing wedged on a dead socket (the
    /// after-sleep case) fails fast for the caller, and its connection is then left strictly alone —
    /// not checked in, not disconnected in ANY mode, not released. Disconnecting it is what crashed:
    /// AMSMB2's graceful teardown races libsmb2 still dispatching callbacks for the pending request.
    @Test("a wedged listing is condemned — never checked in, never disconnected")
    func wedgedListingIsCondemnedNotDisconnected() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let lister = makePooledLister(
            world: world, pool: pool, connectTimeout: Self.subSecondNominalTimeout
        )

        // Warm a connection, then wedge the next listing inside the fake share.
        _ = try await lister.list(share: "Media", path: "")
        await untilSettled { await pool.idleCount == 1 }
        await world.operationGate.close()
        let wedged = Task { try await lister.list(share: "Media", path: "Movies") }

        await #expect(throws: SMBListerError.timedOut) { _ = try await wedged.value }

        #expect(await pool.condemnedCount == 1, "the wedged connection is parked alive")
        #expect(world.disconnectedIDs.isEmpty, "a connection with a pending call is never disconnected")
        #expect(world.tornDownWithPendingOps.isEmpty, "…in any mode, graceful included")
        _ = try await pool.checkout(fakeTarget(host: "nas", share: "Media"))
        #expect(world.connectedIDs == [0, 1], "the condemned connection is never handed out again")

        // Held for the whole time its call is pending: still parked, still untouched.
        #expect(await pool.condemnedCount == 1)
        #expect(world.disconnectedIDs.isEmpty)

        await world.operationGate.open()
    }

    /// The other half: the parked connection is not parked forever when its call DOES come back. The
    /// settle signal releases the reference — and still issues no disconnect, because destroying a
    /// context only ever crashed while requests were pending, and speaking SMB on a socket this
    /// wedged is what the first crash stack was.
    @Test("a condemned connection is released — without a disconnect — once its call settles")
    func settledCallReleasesTheCondemnedConnection() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let lister = makePooledLister(
            world: world, pool: pool, connectTimeout: Self.subSecondNominalTimeout
        )

        _ = try await lister.list(share: "Media", path: "")
        await untilSettled { await pool.idleCount == 1 }
        await world.operationGate.close()
        let wedged = Task { try await lister.list(share: "Media", path: "Movies") }
        await #expect(throws: SMBListerError.timedOut) { _ = try await wedged.value }
        #expect(await pool.condemnedCount == 1)

        // The abandoned native call finally returns.
        await world.operationGate.open()

        await untilSettled { await pool.condemnedCount == 0 }
        #expect(await pool.condemnedCount == 0, "the plot is freed once nothing is pending")
        // The abandoned call resumed on a live connection, and nothing was ever disconnected — so
        // the use-after-free shape had nothing to occur on.
        #expect(world.disconnectedIDs.isEmpty, "releasing a settled connection speaks no SMB")
    }

    /// Cancellation is the same hazard wearing different clothes: the native call cannot observe it,
    /// so a cancelled listing leaves a request pending exactly like a wedged one. It must condemn,
    /// not discard — the old code discarded here, which is a graceful disconnect over a live request.
    @Test("a cancelled listing whose call is still running is condemned, not discarded")
    func cancelledListingWithARunningCallIsCondemned() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let lister = makePooledLister(world: world, pool: pool)

        _ = try await lister.list(share: "Media", path: "")
        await world.operationGate.close()
        let cancelled = Task { try await lister.list(share: "Media", path: "Movies") }
        // Arrival 2 is the wedged listing: proof the native call is genuinely in flight, so the
        // cancellation below can only land on a running call.
        await world.operationGate.awaitArrivals(2)

        cancelled.cancel()
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }

        #expect(await pool.condemnedCount == 1, "a cancelled-with-orphan borrow is parked, not torn down")
        #expect(world.disconnectedIDs.isEmpty)
        #expect(world.tornDownWithPendingOps.isEmpty)

        // …and it leaves the same way any other park does: when the abandoned call finally returns,
        // the reference is dropped and no disconnect is ever issued.
        await world.operationGate.open()
        await untilSettled { await pool.condemnedCount == 0 }
        #expect(await pool.condemnedCount == 0, "the settled call frees the plot")
        #expect(await pool.releasedTotal == 1, "released exactly once")
        #expect(world.disconnectedIDs.isEmpty)
    }

    // MARK: - AMSMB2's own reply timeout (a completed failure that is still pending)

    /// The third state, and the one that used to be mis-sorted: AMSMB2's poll loop gave up and threw,
    /// so nothing was abandoned in the hard-timeout sense and the call RETURNED — but it never
    /// dequeued the request, so libsmb2 still owns it and will still dispatch its callback. The old
    /// code read that as "finished badly" and discarded, which is a graceful disconnect over a live
    /// request. It has to condemn.
    @Test("a listing that hit AMSMB2's own reply timeout is condemned, not discarded")
    func innerTimeoutListingIsCondemned() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let lister = makePooledLister(world: world, pool: pool)
        world.setListingOutcome(.fails(innerTimeoutError))

        await #expect(throws: POSIXError.self) { _ = try await lister.list(share: "Media", path: "") }

        #expect(await pool.condemnedCount == 1, "the request is still queued in libsmb2 — park it")
        #expect(world.disconnectedIDs.isEmpty, "a discard here would be a disconnect over a live request")
        #expect(world.tornDownWithPendingOps.isEmpty)
        _ = try await pool.checkout(fakeTarget(host: "nas", share: "Media"))
        #expect(world.connectedIDs == [0, 1], "the condemned connection is never handed out again")

        // Nothing can ever settle it — libsmb2 gives us no signal that the request retired — so this
        // park is bounded by a FUSE instead, sized off the ceiling the listing ran under. Without it
        // a slow NAS leaks a socket and a server session per timed-out listing.
        await world.fuse.awaitRequests(1)
        #expect(
            await world.fuse.requested == [SMBAbandonedCall.releaseFuse(afterOperationTimeout: 15)],
            "the fuse is derived from the operation ceiling, never typed"
        )
        #expect(await pool.condemnedCount == 1, "parked for the whole fuse")

        await world.fuse.fire()
        await untilSettled { await pool.condemnedCount == 0 }
        #expect(await pool.condemnedCount == 0, "the fuse frees the plot")
        #expect(world.disconnectedIDs.isEmpty, "…and still speaks no SMB on the way out")
    }

    @Test("a share enumeration that hit AMSMB2's own reply timeout is condemned too")
    func innerTimeoutListSharesIsCondemned() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let lister = makePooledLister(world: world, pool: pool)
        world.setShareListOutcome(.fails(innerTimeoutError))

        await #expect(throws: POSIXError.self) { _ = try await lister.listShares() }

        #expect(await pool.condemnedCount == 1)
        #expect(world.disconnectedIDs.isEmpty, "the one-shot connection is parked, not torn down")

        // Same unsettleable receipt as the listing path, so the same fuse ends the park.
        await world.fuse.awaitRequests(1)
        await world.fuse.fire()
        await untilSettled { await pool.condemnedCount == 0 }
        #expect(world.disconnectedIDs.isEmpty, "…and the fused release still speaks no SMB")
    }

    // MARK: - Share enumeration

    /// Share enumeration has no share to borrow against and AMSMB2 runs it over its own IPC$
    /// connection, so it uses a one-shot connection that is torn down instead of pooled.
    @Test("listShares runs on its own connection and never leaves one in the pool")
    func listSharesUsesAThrowawayConnection() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let lister = makePooledLister(world: world, pool: pool)
        world.setShareListOutcome(.shares([SMBShare(name: "Media", comment: "Movies & TV")]))

        let shares = try await lister.listShares()

        #expect(shares == [SMBShare(name: "Media", comment: "Movies & TV")])
        await untilSettled { world.disconnectedIDs == [0] }
        #expect(world.disconnectedIDs == [0], "the enumeration connection is torn down after use")
        _ = try await lister.list(share: "Media", path: "")
        #expect(world.connectedIDs == [0, 1], "the listing had to cold-connect — nothing was pooled")
    }

    /// The failure exit of the one-shot connection. It owns its connection outright, so a thrown
    /// enumeration is the one path that could strand one — nothing else holds a reference to close it.
    @Test("a failed share enumeration still tears its one-shot connection down")
    func listSharesTearsDownAfterAFailure() async throws {
        let world = FakeSMBWorld()
        let lister = makePooledLister(world: world, pool: makeFakePool(world: world))
        world.setShareListOutcome(.fails(ShareFailure()))

        await #expect(throws: ShareFailure.self) { _ = try await lister.listShares() }

        await untilSettled { world.disconnectedIDs == [0] }
        #expect(world.disconnectedIDs == [0], "a thrown enumeration must not strand its connection")
    }

    /// Owning its connection outright does not exempt share enumeration from the law: a wedged
    /// enumeration is condemned like any other pending call. Tearing this one down is the same crash
    /// — the connection just happens to have no pool key.
    @Test("a wedged share enumeration is condemned instead of torn down")
    func wedgedListSharesIsCondemned() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let lister = makePooledLister(
            world: world, pool: pool, connectTimeout: Self.subSecondNominalTimeout
        )
        await world.operationGate.close()

        await #expect(throws: SMBListerError.timedOut) { _ = try await lister.listShares() }

        #expect(await pool.condemnedCount == 1)
        #expect(world.disconnectedIDs.isEmpty, "the one-shot connection is parked, not disconnected")

        // The abandoned enumeration returns → the park ends, exactly as it does for a borrow.
        await world.operationGate.open()
        await untilSettled { await pool.condemnedCount == 0 }
        #expect(await pool.condemnedCount == 0, "the settled call frees the plot")
        #expect(await pool.releasedTotal == 1, "released exactly once")
        #expect(world.disconnectedIDs.isEmpty)
    }
}
