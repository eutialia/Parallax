import AMSMB2
import Foundation
import ParallaxCore

/// `RandomAccessReading` over AMSMB2 (libsmb2 SMB2/3), for container probing, sidecar-image reads,
/// and the localhost HTTP bridge that feeds AVPlayer. Logic-free glue: it maps `read`/`fileSize`
/// onto a single `SMB2Manager`, mirroring `PooledSMBLister`'s connection, credential, and
/// fast-fail-timeout pattern.
///
/// **Pooled connections.** The reader BORROWS a warm connection from an `SMBConnectionPool` on first
/// use and CHECKS IT BACK IN on `disconnect()` — so a scroll through many thumbnails (or a burst of
/// probes) reuses a handful of authenticated share connections rather than re-handshaking one per
/// fetch (4–6 WAN round trips each). The graceful-disconnect crash guard (76d6fcd) lives in the
/// pool's reaper: the pool only ever disconnects a connection while it's idle (zero borrowers), so a
/// checked-in connection is never torn down under a live read.
///
/// **The taint rule (see `disconnect()`).** A clean, fully-completed borrow checks back in reusable.
/// A borrow that saw a thrown read/attributes error is DISCARDED — the pool disconnects it gracefully
/// in the background instead of handing a broken/half-consumed socket to the next borrower. A borrow
/// torn down while a read is still IN FLIGHT (the probe-timeout wedge) is neither: it is CONDEMNED to
/// `SMBConnectionGraveyard`, which never disconnects it and does not even release it until that read
/// returns.
///
/// Concurrency: an `actor`. `SMB2Manager` is a stateful single-share connection, so serialising every
/// `read`/`fileSize`/`disconnect` through the actor keeps the borrow lifecycle race-free.
///
/// Credentials: packed into an `SMBConnectionTarget` (which derives the pool key from a password
/// DIGEST, never the raw secret) and used only to build the `URLCredential` the pool's connector
/// hands `SMB2Manager` — never logged, never embedded in a URL. The file `path` may be logged
/// (matches the `SMBFileSource.mapListError` precedent).
///
/// Generic over `SMBReadableConnection` for the same reason `SMBConnectionPool` is generic over
/// `PoolableSMBConnection`: production instantiates it with `SMB2Manager` (inferred from the pool
/// argument, so no call site names the parameter), and tests inject a fake so the borrow/taint/
/// drain lifecycle is exercised without a share.
public actor SMBRandomAccessReader<Connection: SMBReadableConnection>: RandomAccessReading {

    private let pool: SMBConnectionPool<Connection>
    private let target: SMBConnectionTarget
    private let path: String

    /// Per-operation response timeout on the borrowed manager. AMSMB2 defaults to 60s; a short
    /// LAN-appropriate ceiling fails a wedged read fast instead. The pool owns the CONNECT ceiling;
    /// this bounds only per-read timeouts on an already-borrowed manager.
    private let connectTimeout: TimeInterval

    /// The live borrowed manager, set on first use. Reset by `disconnect()`.
    private var manager: Connection?

    /// The pool borrow backing `manager`. Held so `disconnect()` can check the exact connection back
    /// in (or discard it).
    private var handle: SMBPooledConnection<Connection>?

    /// Set by `disconnect()`, permanently. Guards `connectedManager()` so a straggler read (an
    /// HTTP-bridge serve loop that was already past its own stop check) can't lazily re-borrow a
    /// session that nothing would check back in.
    private var isClosed = false

    /// File size, cached after the first successful `attributesOfItem`. The bridge and probe treat the
    /// first read as authoritative — a mid-walk grow must not shift the size out from under an
    /// in-flight `Content-Range`.
    private var cachedFileSize: UInt64?

    /// The borrow is unreusable: an SMB op threw on it. Combined with `inFlightOps` at
    /// `disconnect()` to decide check-in vs. discard.
    private var tainted = false

    /// An op RETURNED with AMSMB2's own reply timeout, which leaves the request queued inside
    /// libsmb2 (see `SMBAbandonedCall`). `inFlightOps` cannot see this — the call unwound — but the
    /// connection is just as pending, so teardown must condemn rather than discard.
    private var leftRequestQueued = false

    /// Operations currently suspended inside a native AMSMB2 call. Non-zero at `disconnect()` means a
    /// read hasn't unwound (the classic probe-timeout wedge) — the borrow is discarded, not returned.
    private var inFlightOps = 0

    /// Continuations parked by `drainAndDisconnect` until `inFlightOps` reaches zero (or its
    /// deadline fires). Resumed by `opFinished()`.
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    /// The receipt handed to the graveyard when this reader gave up on a still-running read. Signalled
    /// by `opFinished()` when the last op unwinds, which is what lets the condemned connection be
    /// released. Nil whenever nothing has been condemned.
    private var condemnedSettlement: SMBOperationSettlement?

    /// Pooled reader: borrows a warm connection from `pool` on first use and checks it back in on
    /// `disconnect()`.
    /// - Parameters:
    ///   - pool: the shared connection pool to borrow from.
    ///   - host: bare SMB host, e.g. `"192.168.1.10"` (no scheme, no userinfo).
    ///   - username: account user.
    ///   - password: account password — supplied by the caller (Keychain at the call site). Never
    ///     logged, never placed in a URL; folded into the pool key only as a SHA256 digest.
    ///   - domain: SMB/NT domain or workgroup (e.g. `"WORKGROUP"`). Empty is allowed.
    ///   - share: the share to connect (e.g. `"Media"`).
    ///   - path: share-relative file path (e.g. `"Movies/film.mp4"`).
    ///   - connectTimeout: per-read ceiling on the borrowed manager (the pool owns the connect ceiling).
    public init(pool: SMBConnectionPool<Connection>, host: String, username: String, password: String,
                domain: String = "", share: String, path: String, connectTimeout: TimeInterval = 15) {
        self.pool = pool
        self.target = SMBConnectionTarget(
            host: host, username: username, password: password, domain: domain, share: share
        )
        self.path = path
        self.connectTimeout = connectTimeout
    }

    /// Total size in bytes, cached after the first success.
    public var fileSize: UInt64 {
        get async throws {
            if let cachedFileSize { return cachedFileSize }
            let client = try await connectedManager()
            inFlightOps += 1
            defer { opFinished() }
            do {
                let size = UInt64(max(0, try await client.fileSizeOfItem(atPath: path) ?? 0))
                cachedFileSize = size
                return size
            } catch {
                // The borrow saw a real failure — mark it unreusable so `disconnect()` discards it
                // rather than handing a broken socket to the next borrower.
                noteFailure(error)
                throw error
            }
        }
    }

    /// Reads up to `length` bytes at `offset`. Honors the POSIX-pread contract: a read at or past EOF
    /// returns the available prefix (possibly empty). AMSMB2's `contents(atPath:range:)` already
    /// implements this — an out-of-range lowerBound yields empty `Data`, and an over-long range
    /// truncates to the remaining file content — so no manual clamping is needed.
    public func read(offset: UInt64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        let client = try await connectedManager()
        inFlightOps += 1
        defer { opFinished() }
        // SATURATING, not wrapping: an offset within `length` of `UInt64.max` (a corrupt
        // `Content-Range`, a bogus probe seek) would wrap the sum BELOW `offset` and trap the
        // `Range` construction on `lowerBound > upperBound`. Clamping to `UInt64.max` keeps the
        // range valid; being at or past EOF, it simply returns the available (empty) prefix.
        let sum = offset.addingReportingOverflow(UInt64(length))
        let upperBound = sum.overflow ? UInt64.max : sum.partialValue
        do {
            return try await client.readBytes(atPath: path, range: offset..<upperBound)
        } catch let error as POSIXError where error.code == .ENODATA || error.code == .ERANGE {
            // Defensive: if a future AMSMB2 surfaced an EOF-shaped POSIX error instead of a short
            // read, honor the pread contract by returning the empty prefix. NOT a taint — an expected
            // end-of-file shape leaves the connection perfectly reusable.
            return Data()
        } catch {
            noteFailure(error)
            throw error
        }
    }

    /// One place both op paths record a failure: the borrow is unreusable, and — when the failure is
    /// AMSMB2's own reply timeout — the connection additionally still owes libsmb2 a request, which
    /// upgrades teardown from discard to condemn.
    private func noteFailure(_ error: any Error) {
        tainted = true
        if SMBAbandonedCall.leavesRequestQueued(error) { leftRequestQueued = true }
    }

    /// Checks the borrowed connection back into the pool for reuse — or gets rid of it. Idempotent;
    /// the reader is permanently closed afterwards (`read`/`fileSize` throw instead of re-borrowing).
    ///
    /// **The taint rule, in the order it must be asked.**
    ///  - `inFlightOps > 0` — a native read is still stuck in libsmb2's poll loop (the caller's own
    ///    hard timeout fired and it tore the reader down anyway). CONDEMN: this connection may not be
    ///    disconnected in any mode, nor released, until that call returns — see
    ///    `SMBConnectionGraveyard`. Asked FIRST, because a borrow that is both tainted and wedged is
    ///    still a wedged one.
    ///  - `tainted` — an SMB op already errored and returned, so the socket may be in an undefined
    ///    state; returning it would surface a stranger's failure as the next borrower's. DISCARD, the
    ///    background graceful teardown, which has nothing pending to race.
    ///  - otherwise the borrow completed a clean lifecycle and CHECKS IN.
    public func disconnect() async {
        isClosed = true
        manager = nil
        let borrowed = handle
        handle = nil
        guard let borrowed else { return }
        if let pending = pendingCall() {
            await pool.condemn(borrowed, settlement: pending.settlement, releaseAfter: pending.fuse)
        } else if tainted {
            pool.discard(borrowed)
        } else {
            await pool.checkin(borrowed)
        }
    }

    /// Marks the borrow unreusable regardless of how cleanly it ends: `disconnect`/
    /// `drainAndDisconnect` will discard it instead of returning it to the pool. For borrows whose
    /// LIFETIME disqualifies them from reuse — an hours-long playback session's socket may be
    /// silently degraded (stalls surface as short reads, never a thrown error, so `tainted` can't
    /// catch them) and must not become the next thumbnail fetch's "warm" connection.
    public func markUnreusable() {
        tainted = true
    }

    /// Teardown that WAITS (bounded) for in-flight SMB ops to unwind before deciding the borrow's
    /// fate — the bridge-session teardown path. Two things the fast `disconnect()` can't give:
    ///  - **warm reuse on the common frame-grab path**: the zombie thumbnailer usually has one last
    ///    read in flight when the bridge stops; that read finishes within a chunk time, and a clean
    ///    drain lets the connection CHECK IN instead of being discarded — without this, frame-grabs
    ///    consumed warm connections without ever donating any back;
    ///  - **no drain/next-fetch overlap** (the f4ad8c0 tuning): the caller releases its gate permit
    ///    right after teardown returns, so the drain must be AWAITED — a fire-and-forget discard's
    ///    tail would stream over the same WAN link as the next generation's fresh fetch.
    /// The wait is bounded by `connectTimeout`. Past that deadline the outcomes split the same way
    /// `disconnect()` splits them: a tainted borrow whose ops all RETURNED is disconnected gracefully
    /// INLINE (still awaited, still no overlap), while an op still wedged at the deadline is
    /// CONDEMNED — the deadline expiring proves nothing about the native call except that it is still
    /// running, and disconnecting it then is the crash `SMBConnectionGraveyard` documents. Condemning
    /// is also awaited, but it parks a reference rather than draining a socket, so it adds no tail.
    public func drainAndDisconnect() async {
        isClosed = true
        manager = nil
        let borrowed = handle
        handle = nil
        guard let borrowed else { return }
        await waitForDrain(upTo: connectTimeout)
        if let pending = pendingCall() {
            await pool.condemn(borrowed, settlement: pending.settlement, releaseAfter: pending.fuse)
        } else if tainted {
            await borrowed.connection.disconnectGracefully()
        } else {
            await pool.checkin(borrowed)
        }
    }

    /// The receipt to condemn this borrow with — plus the fuse it needs, if any — or nil when the
    /// connection owes nothing.
    ///
    /// Two ways to owe something, and they settle differently:
    ///  - an op is still suspended inside a native call — `opFinished()` settles that receipt when it
    ///    unwinds, and the graveyard releases the connection then. NO fuse: releasing under a call
    ///    that is still running is the disposal the graveyard forbids;
    ///  - an op RETURNED on AMSMB2's reply timeout — the request is still queued in libsmb2 and we
    ///    have no signal at all for when it retires, so this receipt is one nobody ever settles. It
    ///    carries a FUSE instead, which is safe precisely because the call has returned: nothing is
    ///    inside libsmb2 on this context any more (see `SMBConnectionGraveyard`).
    private func pendingCall() -> (settlement: SMBOperationSettlement, fuse: Duration?)? {
        if inFlightOps > 0 { return (settlementForCondemnedOps(), nil) }
        if leftRequestQueued {
            return (
                SMBOperationSettlement(),
                SMBAbandonedCall.releaseFuse(afterOperationTimeout: connectTimeout)
            )
        }
        return nil
    }

    /// The receipt for a connection being condemned right now, signalled by `opFinished()` when the
    /// last in-flight op unwinds. Minted at most once per reader: both teardown paths take `handle`
    /// and nil it before they ask, so a second teardown returns early and never reaches here.
    private func settlementForCondemnedOps() -> SMBOperationSettlement {
        let settlement = SMBOperationSettlement()
        condemnedSettlement = settlement
        return settlement
    }

    /// Suspends until `inFlightOps` reaches zero or `seconds` elapse (a spurious deadline resume is
    /// safe — the caller re-checks `inFlightOps` and takes the disconnect branch).
    private func waitForDrain(upTo seconds: TimeInterval) async {
        guard inFlightOps > 0 else { return }
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.expireDrainWaiters()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if inFlightOps == 0 {
                continuation.resume()
            } else {
                drainWaiters.append(continuation)
            }
        }
        deadline.cancel()
    }

    /// Op-completion bookkeeping shared by `read`/`fileSize` defers: decrement, and when the last op
    /// unwinds, settle a condemned connection's receipt (which releases it) and release any parked
    /// drain waiters.
    private func opFinished() {
        inFlightOps -= 1
        guard inFlightOps == 0 else { return }
        // Nothing pending on this connection any more — whoever condemned it may now let it go.
        condemnedSettlement?.markSettled()
        condemnedSettlement = nil
        guard !drainWaiters.isEmpty else { return }
        let waiters = drainWaiters
        drainWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Deadline path: releases parked drain waiters even though ops remain — `drainAndDisconnect`
    /// re-checks `inFlightOps` and disconnects instead of checking in.
    private func expireDrainWaiters() {
        let waiters = drainWaiters
        drainWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    // MARK: - Connection

    /// Returns the live borrowed manager, checking one out of the pool on first use. ASSUMES a single
    /// caller per instance: the `await` on `checkout` is a suspension point *before* `self.manager` is
    /// set, so two CONCURRENT first reads would borrow two connections (actor reentrancy). The HTTP
    /// bridge fronts this reader from many connections, but it always probes/starts via one
    /// `fileSize`/`read` before serving, and AMSMB2 itself serialises; if concurrent cold-start ever
    /// becomes real, memoize an in-flight checkout `Task` here.
    private func connectedManager() async throws -> Connection {
        // A read that lost the race with `disconnect()` fails like a cancellation — the serve loop it
        // belongs to is being torn down anyway.
        guard !isClosed else { throw CancellationError() }
        if let manager { return manager }

        let borrowed = try await pool.checkout(target)
        // Re-check after the suspension: a `disconnect()` that ran while this checkout was in flight
        // saw `handle == nil` and had nothing to check in. This is a healthy warm connection — return
        // it to the pool for reuse rather than leaking or discarding it.
        if isClosed {
            await pool.checkin(borrowed)
            throw CancellationError()
        }
        // Pin the per-read ceiling on the borrowed manager: a warm reuse inherits the previous
        // borrower's `timeout`, so re-assert ours so a wedged read fails in `connectTimeout` rather
        // than whatever the last borrow left set (or AMSMB2's 60s default).
        borrowed.connection.setOperationTimeout(connectTimeout)
        handle = borrowed
        manager = borrowed.connection
        return borrowed.connection
    }
}

// MARK: - Connection abstraction

/// The reads a pooled SMB connection must serve for `SMBRandomAccessReader`, layered on the pool's
/// own `PoolableSMBConnection` lifecycle contract. Production conforms `SMB2Manager` (below); tests
/// conform a fake, so the borrow/taint/drain lifecycle above is testable without a live share.
///
/// Both members are deliberately thin renames of AMSMB2's own API rather than a wider abstraction:
/// `SMB2Manager`'s `contents(atPath:range:)` is generic over `RangeExpression`, which cannot witness
/// a protocol requirement directly.
public protocol SMBReadableConnection: PoolableSMBConnection {
    /// Size in bytes of the item at `path`, or nil when the server reports none.
    func fileSizeOfItem(atPath path: String) async throws -> Int64?

    /// Bytes in `range`. Honors the POSIX-pread contract: a range at or past EOF yields the
    /// available prefix (possibly empty) rather than throwing.
    func readBytes(atPath path: String, range: Range<UInt64>) async throws -> Data
}

extension SMB2Manager: SMBReadableConnection {
    public func fileSizeOfItem(atPath path: String) async throws -> Int64? {
        try await attributesOfItem(atPath: path).fileSize
    }

    public func readBytes(atPath path: String, range: Range<UInt64>) async throws -> Data {
        try await contents(atPath: path, range: range)
    }
}

/// The production reader specialization — a reader over real `SMB2Manager` share connections.
/// Aliased so app-side owners can name the type without importing AMSMB2, exactly as `SMBSharePool`
/// does for the pool.
public typealias SMBShareReader = SMBRandomAccessReader<SMB2Manager>
