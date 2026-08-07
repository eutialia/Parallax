import Foundation
import os
@testable import ParallaxFileBrowse

/// A controllable wall clock: `SMBConnectionPool` reads time through an injected `now`, so a test can
/// simulate a slow cold connect and TTL expiry without ever sleeping. Starts at a captured
/// `ContinuousClock` instant and only moves when a test (or the fake connector) advances it.
final class FakeClock: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: ContinuousClock().now)
    func now() -> ContinuousClock.Instant { state.withLock { $0 } }
    func advance(by duration: Duration) { state.withLock { $0 = $0.advanced(by: duration) } }
}

/// Shared bookkeeping for the fake SMB layer: it vends monotonically-ided connections, records
/// every connect/disconnect/timeout/read/listing the pool, reader and lister perform, and scripts
/// what those operations do (canned bytes, canned entries, injected failures, held-open suspensions).
///
/// One world backs `SMBConnectionPoolTests` (which only cares about connect/disconnect
/// bookkeeping), `SMBRandomAccessReaderTests` (the read/taint/drain lifecycle) and
/// `PooledSMBListerTests` (the listing borrow lifecycle).
final class FakeSMBWorld: @unchecked Sendable {

    /// What `fileSizeOfItem` does.
    enum FileSizeOutcome {
        /// Report the length of `contents`.
        case fromContents
        /// Report this exact value (nil = the server gave no size).
        case reports(Int64?)
        case fails(any Error)
    }

    /// What `readBytes` does.
    enum ReadOutcome {
        /// Serve the requested slice of `contents`, POSIX-pread style.
        case fromContents
        case fails(any Error)
    }

    /// What `directoryEntries` does.
    enum ListingOutcome {
        case entries([SMBDirectoryEntry])
        case fails(any Error)
    }

    /// What `availableShares` does.
    enum ShareListOutcome {
        case shares([SMBShare])
        case fails(any Error)
    }

    let clock = FakeClock()
    /// Held by `connect`; closed by a test that needs to interleave with an in-flight cold connect.
    let connectGate = AsyncGate()
    /// Held by every borrowed-connection operation (`fileSizeOfItem`, `readBytes`,
    /// `directoryEntries`, `availableShares`) — the in-flight SMB calls.
    ///
    /// The gate is WORLD-global: closing it wedges every connection at once, which is what the tests
    /// that wedge one want anyway.
    let operationGate = AsyncGate()
    /// Held by every `disconnectGracefully`. Closing it models a slow teardown (a real one is a
    /// tree-disconnect plus a logoff round trip), which is how a test proves teardown is off the
    /// caller's critical path and that several teardowns run concurrently rather than in series.
    let teardownGate = AsyncGate()
    /// Drives the graveyard release fuse — see `makeFakePool`. Nothing sleeps for real.
    let fuse = FakeFuseTimer()

    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var nextID = 0
        /// Every call into `connect`, counted BEFORE the injected failure is thrown — see
        /// `connectAttempts`.
        var connectAttempts = 0
        var connected: [Int] = []
        var disconnected: [Int] = []
        /// Ids whose fake connection has actually been DEALLOCATED — recorded from its `deinit`, so
        /// "the last reference was dropped" is an observation rather than an inference.
        var released: [Int] = []
        var latencyByHost: [String: Duration] = [:]
        var connectError: (any Error)?
        /// Whether `connectError` is thrown AFTER the connection has been built and delivered.
        var failsAfterBuilding = false
        var contents = Data()
        var fileSizeOutcome = FileSizeOutcome.fromContents
        var readOutcome = ReadOutcome.fromContents
        var listingOutcome = ListingOutcome.entries([])
        /// Consumed one per listing, ahead of `listingOutcome` — see `setListingScript`.
        var listingScript: [ListingOutcome] = []
        var shareListOutcome = ShareListOutcome.shares([])
        var readRanges: [Range<UInt64>] = []
        var readPaths: [String] = []
        var listedPaths: [String] = []
        var timeoutsSet: [TimeInterval] = []

        /// Native calls currently suspended inside a fake connection operation, per connection id.
        /// This is the fake's model of libsmb2 having a call in flight on a context.
        var inFlightOps: [Int: Int] = [:]
        /// Connections whose teardown has completed — the fake's model of a destroyed context.
        var destroyed: Set<Int> = []
        /// Ids whose teardown was REQUESTED while one of their calls was still pending. Expected and
        /// correct on the discard paths; it is what proves the borrow was handed to teardown
        /// mid-flight rather than quietly checked back in.
        var tornDownWithPendingOps: [Int] = []
        /// Ids whose pending call resumed only AFTER their teardown had already completed — the
        /// use-after-free shape, in fake form; see `useAfterFreeIDs`.
        var resumedAfterTeardown: [Int] = []
    }

    // MARK: - Observations

    /// Cold-connect ATTEMPTS, including the ones `failConnects(with:)` made throw. `connectedIDs`
    /// records only successes, so it cannot distinguish "the pool skipped the connect" from "the pool
    /// tried and the host refused" — the exact difference the probe-failure backoff exists to make.
    /// Assert on this whenever the behaviour under test is a connect that must NOT be attempted.
    var connectAttempts: Int { state.withLock { $0.connectAttempts } }
    var connectedIDs: [Int] { state.withLock { $0.connected } }
    var disconnectedIDs: [Int] { state.withLock { $0.disconnected } }

    /// Ids whose connection has been deallocated. The graveyard's whole promise is "release speaks
    /// no SMB", and a release is by definition the ABSENCE of a call — so the only way to witness
    /// one is to watch the object die. An id here with no matching entry in `disconnectedIDs` is
    /// exactly that promise kept.
    var releasedIDs: [Int] { state.withLock { $0.released } }
    var readRanges: [Range<UInt64>] { state.withLock { $0.readRanges } }
    var readPaths: [String] { state.withLock { $0.readPaths } }
    var listedPaths: [String] { state.withLock { $0.listedPaths } }
    var timeoutsSet: [TimeInterval] { state.withLock { $0.timeoutsSet } }

    /// Ids handed to teardown while one of their native calls was still pending. A borrower that
    /// DISCARDS a wedged connection must appear here; one that checks it back in never will.
    var tornDownWithPendingOps: [Int] { state.withLock { $0.tornDownWithPendingOps } }

    /// Ids whose pending call came back to a connection that had already been destroyed — the
    /// crash this whole layer exists to prevent, observable instead of merely asserted. Non-empty
    /// means something tore a connection down with a call still pending on it.
    var useAfterFreeIDs: [Int] { state.withLock { $0.resumedAfterTeardown } }

    // MARK: - Scripting

    func setLatency(_ duration: Duration, host: String) {
        state.withLock { $0.latencyByHost[host] = duration }
    }

    /// Makes every subsequent `connect` throw; pass nil to let connects succeed again.
    ///
    /// `afterBuilding` models the production shape where the connection EXISTS before the failure:
    /// the connector builds its manager, delivers it, and only then fails attaching the share. What
    /// happens to that already-built connection is the whole question the escrow answers.
    func failConnects(with error: (any Error)?, afterBuilding: Bool = false) {
        state.withLock {
            $0.connectError = error
            $0.failsAfterBuilding = afterBuilding
        }
    }

    func setContents(_ data: Data) {
        state.withLock { $0.contents = data }
    }

    func setFileSizeOutcome(_ outcome: FileSizeOutcome) {
        state.withLock { $0.fileSizeOutcome = outcome }
    }

    func setReadOutcome(_ outcome: ReadOutcome) {
        state.withLock { $0.readOutcome = outcome }
    }

    func setListingOutcome(_ outcome: ListingOutcome) {
        state.withLock { $0.listingOutcome = outcome }
    }

    /// Scripts the next listings one by one, in order — for the retry path, where the SAME call has
    /// to fail on the stale connection and succeed on the fresh one. Once the script runs out,
    /// `listingOutcome` serves again.
    func setListingScript(_ outcomes: [ListingOutcome]) {
        state.withLock { $0.listingScript = outcomes }
    }

    func setShareListOutcome(_ outcome: ShareListOutcome) {
        state.withLock { $0.shareListOutcome = outcome }
    }

    // MARK: - Connection behaviour

    /// The connector wired into the pool: assigns a fresh id, records the connect, and advances the
    /// clock by the host's configured latency to simulate the cold-connect wall time the pool times.
    /// Honors the production make-then-deliver contract (`SMBConnectionBuilder`) — the connection is
    /// handed over the moment it exists, before anything that can fail.
    func connect(
        _ target: SMBConnectionTarget,
        deliver: @Sendable (FakeSMBConnection) -> Void
    ) async throws -> FakeSMBConnection {
        await connectGate.pass()
        // Counted before the throw: a REFUSED connect still cost the round trip a backoff is meant
        // to save, so an attempt-counting assertion must see it.
        state.withLock { $0.connectAttempts += 1 }
        let failure: (error: (any Error)?, afterBuilding: Bool) =
            state.withLock { ($0.connectError, $0.failsAfterBuilding) }
        if let error = failure.error, !failure.afterBuilding { throw error }
        let (id, latency): (Int, Duration) = state.withLock { s in
            let id = s.nextID
            s.nextID += 1
            s.connected.append(id)
            return (id, s.latencyByHost[target.host] ?? .zero)
        }
        let connection = FakeSMBConnection(id: id, world: self)
        deliver(connection)
        if let error = failure.error { throw error }
        clock.advance(by: latency)
        return connection
    }

    /// Called from `FakeSMBConnection.deinit` — see `releasedIDs`.
    fileprivate func recordRelease(_ id: Int) {
        state.withLock { $0.released.append(id) }
    }

    /// Teardown of one connection, in EVERY mode the production code has — including
    /// `gracefully: true`. It destroys the context without waiting for pending calls, because that
    /// is what the captured crash stacks show a graceful `disconnectShare` doing on a wedged socket:
    /// libsmb2 keeps dispatching callbacks for the pending requests while the teardown runs. A
    /// teardown requested mid-call is recorded, and the destroy is visible to any call that resumes
    /// afterwards — that pairing is what `useAfterFreeIDs` reports.
    func disconnect(_ id: Int) async {
        await teardownGate.pass()
        let pending = state.withLock { $0.inFlightOps[id] ?? 0 }
        if pending > 0 {
            state.withLock { $0.tornDownWithPendingOps.append(id) }
        }
        state.withLock {
            $0.destroyed.insert(id)
            $0.disconnected.append(id)
        }
    }

    func recordTimeout(_ seconds: TimeInterval) {
        state.withLock { $0.timeoutsSet.append(seconds) }
    }

    /// Runs one fake native call on connection `id`: counts it in flight for the whole time it is
    /// suspended on `operationGate`, and on resume reports whether the connection was destroyed
    /// underneath it. That report is the fake's stand-in for the libsmb2 use-after-free.
    private func inFlight<T>(_ id: Int, _ body: () async throws -> T) async rethrows -> T {
        state.withLock { $0.inFlightOps[id, default: 0] += 1 }
        await operationGate.pass()
        let wasDestroyed = state.withLock { s -> Bool in
            s.inFlightOps[id, default: 0] -= 1
            return s.destroyed.contains(id)
        }
        if wasDestroyed {
            state.withLock { $0.resumedAfterTeardown.append(id) }
        }
        return try await body()
    }

    func fileSize(id: Int, atPath path: String) async throws -> Int64? {
        try await inFlight(id) {
            let outcome = state.withLock { s -> FileSizeOutcome in
                s.readPaths.append(path)
                return s.fileSizeOutcome
            }
            switch outcome {
            case .fromContents: return Int64(state.withLock { $0.contents.count })
            case .reports(let size): return size
            case .fails(let error): throw error
            }
        }
    }

    func read(id: Int, atPath path: String, range: Range<UInt64>) async throws -> Data {
        try await inFlight(id) {
            let outcome = state.withLock { s -> ReadOutcome in
                s.readPaths.append(path)
                s.readRanges.append(range)
                return s.readOutcome
            }
            if case .fails(let error) = outcome { throw error }
            // POSIX-pread semantics, matching what AMSMB2 gives the reader.
            let data = state.withLock { $0.contents }
            guard range.lowerBound < UInt64(data.count) else { return Data() }
            let lower = Int(range.lowerBound)
            let upper = Int(min(range.upperBound, UInt64(data.count)))
            return data.subdata(in: lower..<upper)
        }
    }

    func listDirectory(id: Int, atPath path: String) async throws -> [SMBDirectoryEntry] {
        try await inFlight(id) {
            let outcome = state.withLock { s -> ListingOutcome in
                s.listedPaths.append(path)
                guard !s.listingScript.isEmpty else { return s.listingOutcome }
                return s.listingScript.removeFirst()
            }
            switch outcome {
            case .entries(let entries): return entries
            case .fails(let error): throw error
            }
        }
    }

    func listShares(id: Int) async throws -> [SMBShare] {
        try await inFlight(id) {
            switch state.withLock({ $0.shareListOutcome }) {
            case .shares(let shares): return shares
            case .fails(let error): throw error
            }
        }
    }
}

/// One fake share connection vended by `FakeSMBWorld`. Every operation routes back to the world so
/// a test asserts on one place regardless of how many connections the pool handed out. Conforms to
/// BOTH borrower protocols so one fake serves the reader and the lister suites alike.
///
/// A CLASS, and deliberately: the real `SMB2Manager` is one, and the graveyard's central claim —
/// that a park ends by dropping the last reference and nothing else — is only testable if a dropped
/// reference is observable. `deinit` reports that to the world, so "released, never disconnected"
/// becomes a fact a test can fail on rather than an inference from silence.
///
/// `Sendable` without `@unchecked`: both stored properties are immutable, and all mutable state
/// lives behind the world's lock.
final class FakeSMBConnection: SMBReadableConnection, SMBListableConnection, Sendable {
    let id: Int
    let world: FakeSMBWorld

    init(id: Int, world: FakeSMBWorld) {
        self.id = id
        self.world = world
    }

    deinit { world.recordRelease(id) }

    func disconnectGracefully() async { await world.disconnect(id) }
    func setOperationTimeout(_ seconds: TimeInterval) { world.recordTimeout(seconds) }
    func fileSizeOfItem(atPath path: String) async throws -> Int64? {
        try await world.fileSize(id: id, atPath: path)
    }
    func readBytes(atPath path: String, range: Range<UInt64>) async throws -> Data {
        try await world.read(id: id, atPath: path, range: range)
    }
    func directoryEntries(atPath path: String) async throws -> [SMBDirectoryEntry] {
        try await world.listDirectory(id: id, atPath: path)
    }
    func availableShares() async throws -> [SMBShare] { try await world.listShares(id: id) }
}

/// A pool wired to `world`, with the background sweep pushed far out by default so only the
/// opportunistic/explicit reaps under test run.
func makeFakePool(
    world: FakeSMBWorld,
    connectTimeout: TimeInterval = 5,
    maxIdlePerKey: Int = 4,
    idleTTL: Duration = .seconds(60),
    sweepInterval: Duration = .seconds(3_600)
) -> SMBConnectionPool<FakeSMBConnection> {
    SMBConnectionPool<FakeSMBConnection>(
        connectTimeout: connectTimeout,
        maxIdlePerKey: maxIdlePerKey,
        idleTTL: idleTTL,
        sweepInterval: sweepInterval,
        now: { [clock = world.clock] in clock.now() },
        connect: { try await world.connect($0, deliver: $1) },
        fuseSleep: { [fuse = world.fuse] duration in await fuse.wait(duration) }
    )
}

/// Checks a connection out and condemns it WITHOUT leaving a reference behind, returning its id.
///
/// The borrow handle lives and dies inside this function on purpose: the graveyard's promise is that
/// it holds the LAST reference and lets go by dropping it, and a test that keeps a handle of its own
/// can never witness that — `world.releasedIDs` would stay empty however correct the code is.
@discardableResult
func condemnFreshBorrow(
    from pool: SMBConnectionPool<FakeSMBConnection>,
    settlement: SMBOperationSettlement,
    releaseAfter fuse: Duration? = nil,
    target: SMBConnectionTarget = fakeTarget()
) async throws -> Int {
    let borrowed = try await pool.checkout(target)
    let id = borrowed.connection.id
    await pool.condemn(borrowed, settlement: settlement, releaseAfter: fuse)
    return id
}

/// AMSMB2's OWN reply timeout, exactly as it reaches our code: a `POSIXError(.ETIMEDOUT)` thrown
/// from its poll loop. It reads like an ordinary completed failure but leaves the request queued
/// inside libsmb2, so every borrow lifecycle has to route it to the graveyard rather than to a
/// discard. Shared so the lister and reader suites test the same error the real one throws.
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
