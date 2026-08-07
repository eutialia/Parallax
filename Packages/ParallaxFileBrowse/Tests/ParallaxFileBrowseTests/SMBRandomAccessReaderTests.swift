import Foundation
import Testing
@testable import ParallaxFileBrowse

/// Drives the reader over a fake pooled connection (`FakeSMBConnection`), so the borrow lifecycle —
/// lazy checkout, the taint rule, the drain, and the close guard — is pinned without a share.
///
/// Time-limited: the drain and wedge tests wait on gates and detached teardowns, so a regression
/// that never signals should fail red rather than hang the whole run.
@Suite("SMBRandomAccessReader", .timeLimit(.minutes(3)))
struct SMBRandomAccessReaderTests {

    private struct ReadFailure: Error {}

    /// 4 KiB of deterministic bytes, `byte[i] == i % 251`.
    private static let fixture = Data((0..<4_096).map { UInt8($0 % 251) })

    private func makeReader(
        world: FakeSMBWorld,
        pool: SMBConnectionPool<FakeSMBConnection>? = nil,
        connectTimeout: TimeInterval = 15
    ) -> SMBRandomAccessReader<FakeSMBConnection> {
        world.setContents(Self.fixture)
        return SMBRandomAccessReader(
            pool: pool ?? makeFakePool(world: world),
            host: "nas", username: "user", password: "pw",
            share: "Media", path: "Movies/Film.mkv",
            connectTimeout: connectTimeout
        )
    }

    // MARK: - Reads

    @Test("read serves the requested slice and asks the share for exactly that range")
    func readServesRequestedRange() async throws {
        let world = FakeSMBWorld()
        let reader = makeReader(world: world)

        let data = try await reader.read(offset: 100, length: 32)

        #expect(data == Self.fixture.subdata(in: 100..<132))
        #expect(world.readRanges == [100..<132])
        #expect(world.readPaths == ["Movies/Film.mkv"], "the share-relative path is passed through verbatim")
    }

    @Test("a read past EOF returns the available prefix (POSIX pread), not an error")
    func readPastEOFReturnsPrefix() async throws {
        let world = FakeSMBWorld()
        let reader = makeReader(world: world)

        let tail = try await reader.read(offset: UInt64(Self.fixture.count) - 10, length: 4_096)
        let beyond = try await reader.read(offset: UInt64(Self.fixture.count) + 1, length: 16)

        #expect(tail.count == 10)
        #expect(beyond.isEmpty)
    }

    /// `offset + length` overflowing `UInt64` used to wrap the upperBound BELOW the offset and trap
    /// the `Range` construction. Saturating at `UInt64.max` keeps the range valid; a lowerBound past
    /// EOF then yields the empty prefix, exactly like any other over-long read.
    @Test("an offset within `length` of UInt64.max clamps instead of trapping",
          arguments: [UInt64.max - 2, UInt64.max - 1, UInt64.max])
    func readNearUInt64MaxSaturates(_ offset: UInt64) async throws {
        let world = FakeSMBWorld()
        let reader = makeReader(world: world)

        let data = try await reader.read(offset: offset, length: 4_096)

        #expect(data.isEmpty, "a range past EOF returns the available prefix (pread contract)")
        #expect(world.readRanges == [offset..<UInt64.max], "the range is clamped, never inverted")
    }

    @Test("a non-positive length short-circuits without borrowing a connection", arguments: [0, -1])
    func nonPositiveLengthNeverBorrows(_ length: Int) async throws {
        let world = FakeSMBWorld()
        let reader = makeReader(world: world)

        let data = try await reader.read(offset: 0, length: length)

        #expect(data.isEmpty)
        #expect(world.connectedIDs.isEmpty, "an empty read must not cost a pool checkout")
    }

    /// AMSMB2 today signals EOF with a short read, but the reader defensively honors an EOF-SHAPED
    /// POSIX error the same way — and, crucially, does not taint the borrow over it.
    @Test("an EOF-shaped POSIX error yields empty data and leaves the borrow reusable",
          arguments: [POSIXErrorCode.ENODATA, .ERANGE])
    func eofShapedPOSIXErrorIsNotATaint(_ code: POSIXErrorCode) async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let reader = makeReader(world: world, pool: pool)
        world.setReadOutcome(.fails(POSIXError(code)))

        let data = try await reader.read(offset: 0, length: 16)
        #expect(data.isEmpty)

        await reader.disconnect()
        #expect(world.disconnectedIDs.isEmpty, "an expected EOF shape must not discard the connection")
        let reused = try await pool.checkout(fakeTarget(host: "nas", share: "Media"))
        #expect(reused.connection.id == 0, "the clean borrow went back to the idle pool")
    }

    // MARK: - fileSize

    @Test("fileSize is fetched once and cached — a second read costs no SMB round trip")
    func fileSizeIsCached() async throws {
        let world = FakeSMBWorld()
        let reader = makeReader(world: world)

        let first = try await reader.fileSize
        let second = try await reader.fileSize

        #expect(first == UInt64(Self.fixture.count))
        #expect(second == first)
        #expect(world.readPaths.count == 1, "the cached size must not re-hit the share")
    }

    /// A server that omits the size, or reports a nonsense negative one, must read as 0 rather than
    /// trapping the `UInt64` conversion.
    @Test("a missing or negative reported size clamps to zero",
          arguments: [(Int64?.none, UInt64(0)), (Int64(-1), UInt64(0)), (Int64(4_096), UInt64(4_096))])
    func fileSizeClampsToZero(_ reported: Int64?, _ expected: UInt64) async throws {
        let world = FakeSMBWorld()
        let reader = makeReader(world: world)
        world.setFileSizeOutcome(.reports(reported))

        let size = try await reader.fileSize
        #expect(size == expected)
    }

    @Test("the borrowed connection's per-operation ceiling is re-pinned on checkout")
    func borrowPinsOperationTimeout() async throws {
        let world = FakeSMBWorld()
        let reader = makeReader(world: world, connectTimeout: 7)

        _ = try await reader.fileSize

        #expect(world.timeoutsSet == [7], "a warm reuse inherits the last borrower's timeout — re-assert ours")
    }

    // MARK: - Transport fault flag

    @Test("a clean read leaves hadTransportFault false")
    func cleanReadDoesNotMarkTransportFault() async throws {
        let world = FakeSMBWorld()
        let reader = makeReader(world: world)

        _ = try await reader.read(offset: 0, length: 16)

        #expect(await reader.hadTransportFault == false)
    }

    @Test("a transport-class read error flips hadTransportFault")
    func transportClassReadMarksTransportFault() async throws {
        let world = FakeSMBWorld()
        let reader = makeReader(world: world)
        world.setReadOutcome(.fails(POSIXError(.ECONNRESET)))

        await #expect(throws: POSIXError.self) {
            _ = try await reader.read(offset: 0, length: 16)
        }

        #expect(await reader.hadTransportFault == true)
    }

    /// The checkout is a network phase too, and it used to sit OUTSIDE the classified region: every
    /// refused/unreachable/timed-out cold connect left the flag false, so the thumbnail poison guard
    /// blamed the file for a reachability blip. Both ops must classify their borrow.
    @Test("a connect-class failure flips hadTransportFault on both ops",
          arguments: [ReaderOp.read, .fileSize])
    func connectFailureMarksTransportFault(_ op: ReaderOp) async throws {
        let world = FakeSMBWorld()
        let reader = makeReader(world: world)
        world.failConnects(with: innerTimeoutError)

        await #expect(throws: POSIXError.self) { try await op.run(reader) }

        #expect(await reader.hadTransportFault == true)
    }

    /// The two entry points that borrow a connection, so the connect-phase classification is pinned
    /// on both rather than only on whichever one a single test happened to call.
    enum ReaderOp: Sendable, CustomTestStringConvertible {
        case read
        case fileSize

        var testDescription: String {
            switch self {
            case .read: return "read"
            case .fileSize: return "fileSize"
            }
        }

        func run(_ reader: SMBRandomAccessReader<FakeSMBConnection>) async throws {
            switch self {
            case .read: _ = try await reader.read(offset: 0, length: 16)
            case .fileSize: _ = try await reader.fileSize
            }
        }
    }

    @Test("a non-transport read error leaves hadTransportFault false")
    func contentLevelReadDoesNotMarkTransportFault() async throws {
        let world = FakeSMBWorld()
        let reader = makeReader(world: world)
        // A plain Error has no POSIX code — content/decode shape, not a socket death.
        world.setReadOutcome(.fails(ReadFailure()))

        await #expect(throws: ReadFailure.self) {
            _ = try await reader.read(offset: 0, length: 16)
        }

        #expect(await reader.hadTransportFault == false)
    }

    // MARK: - The taint rule

    @Test("a clean borrow is checked back into the pool and reused")
    func cleanBorrowIsCheckedIn() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let reader = makeReader(world: world, pool: pool)

        _ = try await reader.read(offset: 0, length: 16)
        await reader.disconnect()

        #expect(world.disconnectedIDs.isEmpty)
        let reused = try await pool.checkout(fakeTarget(host: "nas", share: "Media"))
        #expect(reused.connection.id == 0)
        #expect(world.connectedIDs == [0], "the returned connection is reused, not reconnected")
    }

    @Test("a borrow whose read threw is discarded, never handed to the next borrower")
    func thrownReadDiscardsTheBorrow() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let reader = makeReader(world: world, pool: pool)
        world.setReadOutcome(.fails(ReadFailure()))

        await #expect(throws: ReadFailure.self) {
            _ = try await reader.read(offset: 0, length: 16)
        }
        await reader.disconnect()
        await untilSettled { world.disconnectedIDs == [0] }

        #expect(world.disconnectedIDs == [0], "the tainted socket is disconnected, not pooled")
        #expect(
            await pool.condemnedCount == 0,
            "the read RETURNED an error — the proven discard path owns this, not the graveyard"
        )
        _ = try await pool.checkout(fakeTarget(host: "nas", share: "Media"))
        #expect(world.connectedIDs == [0, 1], "nothing idle was left to reuse — the next borrow is cold")
    }

    @Test("a borrow whose fileSize threw is discarded too")
    func thrownFileSizeDiscardsTheBorrow() async throws {
        let world = FakeSMBWorld()
        let reader = makeReader(world: world)
        world.setFileSizeOutcome(.fails(ReadFailure()))

        await #expect(throws: ReadFailure.self) { _ = try await reader.fileSize }
        await reader.disconnect()
        await untilSettled { world.disconnectedIDs == [0] }

        #expect(world.disconnectedIDs == [0])
    }

    /// The two ops the reader runs, each paired with the teardown that follows it in production —
    /// the fast `disconnect()` after a read, the draining one after a probe's `fileSize`. Both must
    /// route AMSMB2's reply timeout identically.
    enum ReplyTimeoutCase: Sendable, CustomTestStringConvertible {
        case readThenDisconnect
        case fileSizeThenDrain

        var testDescription: String {
            switch self {
            case .readThenDisconnect: return "read, then disconnect()"
            case .fileSizeThenDrain: return "fileSize, then drainAndDisconnect()"
            }
        }
    }

    /// AMSMB2's own reply timeout is a completed failure that is NOT quiet: its poll loop gave up
    /// without dequeuing the request, so libsmb2 still owns it. `inFlightOps` is back at zero (the
    /// call unwound), which is exactly why the old code discarded it — a graceful disconnect over a
    /// live request. It has to condemn instead, on both teardown paths.
    @Test("an op that hit AMSMB2's own reply timeout condemns the borrow instead of discarding it",
          arguments: [ReplyTimeoutCase.readThenDisconnect, .fileSizeThenDrain])
    func innerTimeoutCondemnsTheBorrow(_ scenario: ReplyTimeoutCase) async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let reader = makeReader(world: world, pool: pool)

        switch scenario {
        case .readThenDisconnect:
            world.setReadOutcome(.fails(innerTimeoutError))
            await #expect(throws: POSIXError.self) { _ = try await reader.read(offset: 0, length: 16) }
            await reader.disconnect()
        case .fileSizeThenDrain:
            world.setFileSizeOutcome(.fails(innerTimeoutError))
            await #expect(throws: POSIXError.self) { _ = try await reader.fileSize }
            await reader.drainAndDisconnect()
        }

        #expect(await pool.condemnedCount == 1, "the request is still queued in libsmb2 — park it")
        #expect(world.disconnectedIDs.isEmpty, "no disconnect, in any mode, over a live request")
        _ = try await pool.checkout(fakeTarget(host: "nas", share: "Media"))
        #expect(world.connectedIDs == [0, 1], "the condemned connection is never handed out again")

        // Nothing will ever settle this receipt, so the park is bounded by a fuse instead — otherwise
        // every slow op leaks a socket and a server session. The op's own ceiling sizes it.
        await world.fuse.awaitRequests(1)
        #expect(await world.fuse.requested == [SMBAbandonedCall.releaseFuse(afterOperationTimeout: 15)])
        await world.fuse.fire()
        await untilSettled { await pool.condemnedCount == 0 }
        #expect(await pool.condemnedCount == 0, "the fuse frees the plot")
        #expect(world.disconnectedIDs.isEmpty, "…without speaking any SMB")
    }

    /// A long playback session's socket may be silently degraded without any op ever throwing, so
    /// its borrow must be disqualified explicitly rather than becoming the next fetch's "warm" one.
    @Test("markUnreusable discards an otherwise clean borrow")
    func markUnreusableDiscardsACleanBorrow() async throws {
        let world = FakeSMBWorld()
        let reader = makeReader(world: world)

        _ = try await reader.read(offset: 0, length: 16)
        await reader.markUnreusable()
        await reader.disconnect()
        await untilSettled { world.disconnectedIDs == [0] }

        #expect(world.disconnectedIDs == [0])
    }

    // MARK: - Close semantics

    @Test("disconnect before any read leaves the pool untouched")
    func disconnectWithoutABorrowTouchesNothing() async {
        let world = FakeSMBWorld()
        let reader = makeReader(world: world)

        await reader.disconnect()

        #expect(world.connectedIDs.isEmpty)
        #expect(world.disconnectedIDs.isEmpty)
    }

    /// The straggler-read guard: an HTTP-bridge serve loop already past its own stop check must not
    /// lazily borrow a connection nothing would ever check back in.
    @Test("a read after disconnect throws CancellationError instead of re-borrowing")
    func readAfterDisconnectNeverBorrows() async {
        let world = FakeSMBWorld()
        let reader = makeReader(world: world)

        await reader.disconnect()
        await reader.disconnect()   // idempotent

        await #expect(throws: CancellationError.self) {
            _ = try await reader.read(offset: 0, length: 1)
        }
        await #expect(throws: CancellationError.self) {
            _ = try await reader.fileSize
        }
        #expect(world.connectedIDs.isEmpty, "a closed reader must never check a connection out")
    }

    /// `connectedManager` re-checks `isClosed` after the checkout suspension: the `disconnect()`
    /// that ran mid-checkout saw no handle to return, so the healthy connection has to be checked in
    /// there rather than leaked or discarded.
    @Test("a disconnect racing an in-flight checkout returns the connection to the pool")
    func disconnectDuringCheckoutReturnsTheConnection() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let reader = makeReader(world: world, pool: pool)
        await world.connectGate.close()

        let read = Task { try await reader.read(offset: 0, length: 16) }
        await world.connectGate.awaitArrivals()   // the checkout is suspended inside the connector

        await reader.disconnect()
        await world.connectGate.open()

        await #expect(throws: CancellationError.self) { _ = try await read.value }
        #expect(world.disconnectedIDs.isEmpty, "the connection was healthy — pool it, don't tear it down")
        let reused = try await pool.checkout(fakeTarget(host: "nas", share: "Media"))
        #expect(reused.connection.id == 0)
        #expect(world.connectedIDs == [0])
    }

    @Test("fileSize keeps serving its cached value after disconnect")
    func cachedFileSizeSurvivesDisconnect() async throws {
        let world = FakeSMBWorld()
        let reader = makeReader(world: world)

        let size = try await reader.fileSize
        await reader.disconnect()
        let afterClose = try await reader.fileSize

        #expect(afterClose == size, "a cached size needs no connection to answer")
    }

    // MARK: - drainAndDisconnect

    @Test("drainAndDisconnect with nothing borrowed is a no-op")
    func drainWithoutABorrowIsANoOp() async {
        let world = FakeSMBWorld()
        let reader = makeReader(world: world)

        await reader.drainAndDisconnect()

        #expect(world.connectedIDs.isEmpty)
        #expect(world.disconnectedIDs.isEmpty)
    }

    @Test("drainAndDisconnect on a settled borrow checks it back in")
    func drainOnASettledBorrowChecksIn() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let reader = makeReader(world: world, pool: pool)

        _ = try await reader.read(offset: 0, length: 16)
        await reader.drainAndDisconnect()

        #expect(world.disconnectedIDs.isEmpty)
        let reused = try await pool.checkout(fakeTarget(host: "nas", share: "Media"))
        #expect(reused.connection.id == 0)
    }

    /// The warm-reuse point of draining at all: the bridge's last frame-grab read is usually still
    /// in flight when teardown starts, and letting it unwind returns the connection to the pool
    /// instead of burning it.
    @Test("drainAndDisconnect waits for an in-flight read, then still checks the borrow in")
    func drainWaitsForAnInFlightRead() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let reader = makeReader(world: world, pool: pool)

        // Warm the borrow, then hold the NEXT read open inside the fake share.
        _ = try await reader.read(offset: 0, length: 16)
        await world.operationGate.close()
        let held = Task { try await reader.read(offset: 16, length: 16) }
        await world.operationGate.awaitArrivals(2)

        let drain = Task { await reader.drainAndDisconnect() }
        await world.operationGate.open()
        _ = try await held.value
        await drain.value

        #expect(world.disconnectedIDs.isEmpty, "the drained borrow is reusable")
        let reused = try await pool.checkout(fakeTarget(host: "nas", share: "Media"))
        #expect(reused.connection.id == 0)
    }

    /// The deadline expiring says only one thing about the wedged read: it is STILL RUNNING. So the
    /// borrow is condemned — parked alive, never returned to the pool and never disconnected (the
    /// graceful teardown that used to run here is the captured crash). Releasing it waits for the
    /// read to come back on its own.
    @Test("a read still wedged at the drain deadline is condemned instead of disconnected")
    func drainDeadlineCondemnsAWedgedBorrow() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        // The drain wait is bounded by connectTimeout; a short one keeps the deadline path quick.
        let reader = makeReader(world: world, pool: pool, connectTimeout: 0.05)

        _ = try await reader.read(offset: 0, length: 16)
        await world.operationGate.close()
        let wedged = Task { try await reader.read(offset: 16, length: 16) }
        await world.operationGate.awaitArrivals(2)

        await reader.drainAndDisconnect()

        #expect(await pool.condemnedCount == 1, "the wedged borrow is parked")
        #expect(world.disconnectedIDs.isEmpty, "a borrow with a pending read is never disconnected")
        #expect(world.tornDownWithPendingOps.isEmpty)
        _ = try await pool.checkout(fakeTarget(host: "nas", share: "Media"))
        #expect(world.connectedIDs == [0, 1], "nothing idle was left — the next borrow is cold")

        // The wedged read finally returns → the plot is freed, still without a disconnect (so the
        // resumed read found a live connection: the use-after-free shape had nothing to occur on).
        await world.operationGate.open()
        _ = try? await wedged.value
        await untilSettled { await pool.condemnedCount == 0 }
        #expect(await pool.condemnedCount == 0)
        #expect(await pool.releasedTotal == 1, "released exactly once, by the settlement")
        #expect(world.disconnectedIDs.isEmpty)
    }

    /// The fast teardown has the same split, and it is the one the sidecar thumbnail path takes: its
    /// caller bounds `read` with its own hard timeout and then calls `disconnect()` while the native
    /// read is still in libsmb2's poll loop. That must condemn, not discard.
    @Test("disconnect with a read still in flight condemns the borrow")
    func disconnectWithAnInFlightReadCondemns() async throws {
        let world = FakeSMBWorld()
        let pool = makeFakePool(world: world)
        let reader = makeReader(world: world, pool: pool)

        _ = try await reader.read(offset: 0, length: 16)
        await world.operationGate.close()
        let wedged = Task { try await reader.read(offset: 16, length: 16) }
        await world.operationGate.awaitArrivals(2)

        await reader.disconnect()

        #expect(await pool.condemnedCount == 1)
        #expect(world.disconnectedIDs.isEmpty, "the abandoned read still owns this connection")
        #expect(world.tornDownWithPendingOps.isEmpty, "…in any mode, graceful included")
        _ = try await pool.checkout(fakeTarget(host: "nas", share: "Media"))
        #expect(world.connectedIDs == [0, 1], "the condemned connection is never handed out again")

        // The abandoned read returns → the plot is freed, and still nothing was disconnected.
        await world.operationGate.open()
        _ = try? await wedged.value
        await untilSettled { await pool.condemnedCount == 0 }
        #expect(await pool.condemnedCount == 0, "the settled read frees the plot")
        #expect(await pool.releasedTotal == 1, "released exactly once")
        #expect(world.disconnectedIDs.isEmpty)
    }
}
