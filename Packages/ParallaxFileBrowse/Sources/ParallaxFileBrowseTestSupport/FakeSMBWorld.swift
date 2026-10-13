import Foundation
import os
import ParallaxCoreTestSupport
import ParallaxFileBrowse

/// A controllable wall clock: `SMBConnectionPool` reads time through an injected `now`, so a test can
/// simulate a slow cold connect and TTL expiry without ever sleeping. Starts at a captured
/// `ContinuousClock` instant and only moves when a test (or the fake connector) advances it.
public final class FakeClock: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: ContinuousClock().now)
    public init() {}
    public func now() -> ContinuousClock.Instant { state.withLock { $0 } }
    public func advance(by duration: Duration) { state.withLock { $0 = $0.advanced(by: duration) } }
}

/// Shared bookkeeping for the fake SMB layer: it vends monotonically-ided connections, records
/// every connect/disconnect/timeout/read/listing the pool, reader and lister perform, and scripts
/// what those operations do (canned bytes, canned entries, injected failures, held-open suspensions).
///
/// One world backs `SMBConnectionPoolTests` (which only cares about connect/disconnect
/// bookkeeping), `SMBRandomAccessReaderTests` (the read/taint/drain lifecycle) and
/// `PooledSMBListerTests` (the listing borrow lifecycle).
public final class FakeSMBWorld: @unchecked Sendable {

    public init() {}

    /// What `fileSizeOfItem` does.
    public enum FileSizeOutcome: Sendable {
        /// Report the length of `contents`.
        case fromContents
        /// Report this exact value (nil = the server gave no size).
        case reports(Int64?)
        case fails(any Error)
    }

    /// What `readBytes` does.
    public enum ReadOutcome: Sendable {
        /// Serve the requested slice of `contents`, POSIX-pread style.
        case fromContents
        case fails(any Error)
    }

    /// What `directoryEntries` does.
    public enum ListingOutcome: Sendable {
        case entries([SMBDirectoryEntry])
        case fails(any Error)
    }

    /// What `availableShares` does.
    public enum ShareListOutcome: Sendable {
        case shares([SMBShare])
        case fails(any Error)
    }

    public let clock = FakeClock()
    /// Held by `connect`; closed by a test that needs to interleave with an in-flight cold connect.
    public let connectGate = AsyncGate()
    /// Held by every borrowed-connection operation (`fileSizeOfItem`, `readBytes`,
    /// `directoryEntries`, `availableShares`) — the in-flight SMB calls.
    ///
    /// The gate is WORLD-global: closing it wedges every connection at once, which is what the tests
    /// that wedge one want anyway.
    public let operationGate = AsyncGate()
    /// Held by every `disconnectGracefully`. Closing it models a slow teardown (a real one is a
    /// tree-disconnect plus a logoff round trip), which is how a test proves teardown is off the
    /// caller's critical path and that several teardowns run concurrently rather than in series.
    public let teardownGate = AsyncGate()

    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var nextID = 0
        /// Every call into `connect`, counted BEFORE the injected failure is thrown — see
        /// `connectAttempts`.
        var connectAttempts = 0
        var connected: [Int] = []
        var disconnected: [Int] = []
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
        /// Per-folder listings, consulted ahead of the script and the global outcome.
        var folders: [FolderKey: [SMBDirectoryEntry]] = [:]
        /// When set, a connect presenting any other password is refused the way a NAS refuses it.
        var password: String?
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
    public var connectAttempts: Int { state.withLock { $0.connectAttempts } }
    public var connectedIDs: [Int] { state.withLock { $0.connected } }
    public var disconnectedIDs: [Int] { state.withLock { $0.disconnected } }

    public var readRanges: [Range<UInt64>] { state.withLock { $0.readRanges } }
    public var readPaths: [String] { state.withLock { $0.readPaths } }
    public var listedPaths: [String] { state.withLock { $0.listedPaths } }
    public var timeoutsSet: [TimeInterval] { state.withLock { $0.timeoutsSet } }

    /// Ids handed to teardown while one of their native calls was still pending. A borrower that
    /// DISCARDS a wedged connection must appear here; one that checks it back in never will.
    public var tornDownWithPendingOps: [Int] { state.withLock { $0.tornDownWithPendingOps } }

    /// Ids whose pending call came back to a connection that had already been destroyed — the
    /// crash this whole layer exists to prevent, observable instead of merely asserted. Non-empty
    /// means something tore a connection down with a call still pending on it.
    public var useAfterFreeIDs: [Int] { state.withLock { $0.resumedAfterTeardown } }

    // MARK: - Scripting

    public func setLatency(_ duration: Duration, host: String) {
        state.withLock { $0.latencyByHost[host] = duration }
    }

    /// Makes every subsequent `connect` throw; pass nil to let connects succeed again.
    ///
    /// `afterBuilding` models the production shape where the connection EXISTS before the failure:
    /// the connector builds its manager, delivers it, and only then fails attaching the share. What
    /// happens to that already-built connection is the whole question the escrow answers.
    public func failConnects(with error: (any Error)?, afterBuilding: Bool = false) {
        state.withLock {
            $0.connectError = error
            $0.failsAfterBuilding = afterBuilding
        }
    }

    public func setContents(_ data: Data) {
        state.withLock { $0.contents = data }
    }

    public func setFileSizeOutcome(_ outcome: FileSizeOutcome) {
        state.withLock { $0.fileSizeOutcome = outcome }
    }

    public func setReadOutcome(_ outcome: ReadOutcome) {
        state.withLock { $0.readOutcome = outcome }
    }

    public func setListingOutcome(_ outcome: ListingOutcome) {
        state.withLock { $0.listingOutcome = outcome }
    }

    /// Scripts the next listings one by one, in order — for the retry path, where the SAME call has
    /// to fail on the stale connection and succeed on the fresh one. Once the script runs out,
    /// `listingOutcome` serves again.
    public func setListingScript(_ outcomes: [ListingOutcome]) {
        state.withLock { $0.listingScript = outcomes }
    }

    public func setShareListOutcome(_ outcome: ShareListOutcome) {
        state.withLock { $0.shareListOutcome = outcome }
    }

    /// What one folder of one share lists. `path` is share-relative; the root is `""`.
    public func setFolder(_ entries: [SMBDirectoryEntry], share: String, path: String = "") {
        state.withLock { $0.folders[FolderKey(share: share, path: path)] = entries }
    }

    /// Refuses every connect that doesn't present `password`, with libsmb2's sign-in refusal.
    public func acceptOnly(password: String) {
        state.withLock { $0.password = password }
    }

    /// The production connection graph (`SMBConnections`) over this world: the real pool, listers
    /// and readers, with only the connections faked. Hard timeouts wait on `clock`.
    public func connections(clock: any Clock<Duration>) -> SMBConnections {
        SMBConnections(pool: makeFakePool(world: self, clock: clock)) { try await self.connect($0, deliver: $1) }
    }

    // MARK: - Connection behaviour

    /// The connector wired into the pool: assigns a fresh id, records the connect, and advances the
    /// clock by the host's configured latency to simulate the cold-connect wall time the pool times.
    /// Honors the production make-then-deliver contract (`SMBConnectionBuilder`) — the connection is
    /// handed over the moment it exists, before anything that can fail.
    public func connect(
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
        if let password = state.withLock({ $0.password }), password != target.password {
            throw POSIXError(.EPERM)
        }
        let (id, latency): (Int, Duration) = state.withLock { s in
            let id = s.nextID
            s.nextID += 1
            s.connected.append(id)
            return (id, s.latencyByHost[target.host] ?? .zero)
        }
        let connection = FakeSMBConnection(id: id, world: self, share: target.share)
        deliver(connection)
        if let error = failure.error { throw error }
        clock.advance(by: latency)
        return connection
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

    func listDirectory(id: Int, share: String, atPath path: String) async throws -> [SMBDirectoryEntry] {
        try await inFlight(id) {
            let outcome = state.withLock { s -> ListingOutcome in
                s.listedPaths.append(path)
                if let entries = s.folders[FolderKey(share: share, path: path)] { return .entries(entries) }
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
/// A CLASS, like the real `SMB2Manager`.
///
/// `Sendable` without `@unchecked`: both stored properties are immutable, and all mutable state
/// lives behind the world's lock.
public final class FakeSMBConnection: SMBReadableConnection, SMBListableConnection, Sendable {
    public let id: Int
    let world: FakeSMBWorld
    /// The share this connection attached; empty for share enumeration's server-level connection.
    let share: String

    init(id: Int, world: FakeSMBWorld, share: String) {
        self.id = id
        self.world = world
        self.share = share
    }

    public func disconnectGracefully() async { await world.disconnect(id) }
    public func setOperationTimeout(_ seconds: TimeInterval) { world.recordTimeout(seconds) }
    public func fileSizeOfItem(atPath path: String) async throws -> Int64? {
        try await world.fileSize(id: id, atPath: path)
    }
    public func readBytes(atPath path: String, range: Range<UInt64>) async throws -> Data {
        try await world.read(id: id, atPath: path, range: range)
    }
    public func directoryEntries(atPath path: String) async throws -> [SMBDirectoryEntry] {
        try await world.listDirectory(id: id, share: share, atPath: path)
    }
    public func availableShares() async throws -> [SMBShare] { try await world.listShares(id: id) }
}

/// A pool wired to `world`, with the background sweep pushed far out by default so only the
/// opportunistic/explicit reaps under test run. Its hard timeouts wait on `clock`, which by default
/// nobody advances: only a test that passes its own clock sees one fire.
public func makeFakePool(
    world: FakeSMBWorld,
    connectTimeout: TimeInterval = 5,
    maxIdlePerKey: Int = 4,
    idleTTL: Duration = .seconds(60),
    sweepInterval: Duration = .seconds(3_600),
    clock: any Clock<Duration> = TestClock()
) -> SMBConnectionPool<FakeSMBConnection> {
    SMBConnectionPool<FakeSMBConnection>(
        connectTimeout: connectTimeout,
        maxIdlePerKey: maxIdlePerKey,
        idleTTL: idleTTL,
        sweepInterval: sweepInterval,
        now: { [clock = world.clock] in clock.now() },
        clock: clock,
        connect: { try await world.connect($0, deliver: $1) }
    )
}


/// A folder of a share, with the path's slashes trimmed so the lister's `/` root and a scenario's
/// `""` name the same folder.
struct FolderKey: Hashable {
    let share: String
    let path: String

    init(share: String, path: String) {
        self.share = share
        self.path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
