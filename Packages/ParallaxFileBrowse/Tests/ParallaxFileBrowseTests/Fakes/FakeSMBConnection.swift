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
/// every connect/disconnect/timeout/read the pool and reader perform, and scripts what those
/// operations do (canned bytes, injected failures, held-open suspensions).
///
/// One world backs both `SMBConnectionPoolTests` (which only cares about connect/disconnect
/// bookkeeping) and `SMBRandomAccessReaderTests` (which drives the read/taint/drain lifecycle).
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

    let clock = FakeClock()
    /// Held by `connect`; closed by a test that needs to interleave with an in-flight cold connect.
    let connectGate = AsyncGate()
    /// Held by `fileSizeOfItem`/`readBytes` — the reader's in-flight SMB operations.
    let operationGate = AsyncGate()

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
        var contents = Data()
        var fileSizeOutcome = FileSizeOutcome.fromContents
        var readOutcome = ReadOutcome.fromContents
        var readRanges: [Range<UInt64>] = []
        var readPaths: [String] = []
        var timeoutsSet: [TimeInterval] = []
    }

    // MARK: - Observations

    /// Cold-connect ATTEMPTS, including the ones `failConnects(with:)` made throw. `connectedIDs`
    /// records only successes, so it cannot distinguish "the pool skipped the connect" from "the pool
    /// tried and the host refused" — the exact difference the probe-failure backoff exists to make.
    /// Assert on this whenever the behaviour under test is a connect that must NOT be attempted.
    var connectAttempts: Int { state.withLock { $0.connectAttempts } }
    var connectedIDs: [Int] { state.withLock { $0.connected } }
    var disconnectedIDs: [Int] { state.withLock { $0.disconnected } }
    var readRanges: [Range<UInt64>] { state.withLock { $0.readRanges } }
    var readPaths: [String] { state.withLock { $0.readPaths } }
    var timeoutsSet: [TimeInterval] { state.withLock { $0.timeoutsSet } }

    // MARK: - Scripting

    func setLatency(_ duration: Duration, host: String) {
        state.withLock { $0.latencyByHost[host] = duration }
    }

    /// Makes every subsequent `connect` throw; pass nil to let connects succeed again.
    func failConnects(with error: (any Error)?) {
        state.withLock { $0.connectError = error }
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

    // MARK: - Connection behaviour

    /// The connector wired into the pool: assigns a fresh id, records the connect, and advances the
    /// clock by the host's configured latency to simulate the cold-connect wall time the pool times.
    func connect(_ target: SMBConnectionTarget) async throws -> FakeSMBConnection {
        await connectGate.pass()
        // Counted before the throw: a REFUSED connect still cost the round trip a backoff is meant
        // to save, so an attempt-counting assertion must see it.
        state.withLock { $0.connectAttempts += 1 }
        if let error = state.withLock({ $0.connectError }) { throw error }
        let (id, latency): (Int, Duration) = state.withLock { s in
            let id = s.nextID
            s.nextID += 1
            s.connected.append(id)
            return (id, s.latencyByHost[target.host] ?? .zero)
        }
        clock.advance(by: latency)
        return FakeSMBConnection(id: id, world: self)
    }

    func recordDisconnect(_ id: Int) {
        state.withLock { $0.disconnected.append(id) }
    }

    func recordTimeout(_ seconds: TimeInterval) {
        state.withLock { $0.timeoutsSet.append(seconds) }
    }

    func fileSize(atPath path: String) async throws -> Int64? {
        await operationGate.pass()
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

    func read(atPath path: String, range: Range<UInt64>) async throws -> Data {
        await operationGate.pass()
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

/// One fake share connection vended by `FakeSMBWorld`. Every operation routes back to the world so
/// a test asserts on one place regardless of how many connections the pool handed out.
struct FakeSMBConnection: SMBReadableConnection {
    let id: Int
    let world: FakeSMBWorld

    func disconnectGracefully() async { world.recordDisconnect(id) }
    func setOperationTimeout(_ seconds: TimeInterval) { world.recordTimeout(seconds) }
    func fileSizeOfItem(atPath path: String) async throws -> Int64? { try await world.fileSize(atPath: path) }
    func readBytes(atPath path: String, range: Range<UInt64>) async throws -> Data {
        try await world.read(atPath: path, range: range)
    }
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
        connect: { try await world.connect($0) }
    )
}

/// A target for the fake pool. Defaults are irrelevant to every assertion except the ones that
/// vary a field on purpose (host for link class, password for key derivation).
func fakeTarget(host: String = "host", share: String = "share", password: String = "pw") -> SMBConnectionTarget {
    SMBConnectionTarget(host: host, username: "user", password: password, share: share)
}
