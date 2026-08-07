import Foundation

/// How to tell, from a thrown error alone, that a connection still has a native request pending.
///
/// The obvious signal is `SMBOperationSettlement.isAbandoned` — we gave up while the Swift call was
/// still running. This is the LESS obvious one: the Swift call returned, and returned an error, and
/// the connection is still not quiet.
enum SMBAbandonedCall {

    /// Whether `error` is AMSMB2's own reply timeout, which leaves the request queued inside libsmb2.
    ///
    /// AMSMB2 bounds a reply with its own poll loop and throws `ETIMEDOUT` when its `timeout`
    /// expires — but it does not cancel or dequeue the request, because libsmb2 has no way to. So
    /// the call has "finished" from Swift's side while the connection is in exactly the state the
    /// graveyard exists for: libsmb2 still owns the request and will still dispatch its callback.
    /// Treating that as an ordinary failure would DISCARD the connection, and a discard is a
    /// graceful disconnect over a live request — the crash this whole layer avoids.
    ///
    /// Matched through both surfaces because a `POSIXError` that crosses an `NSError` boundary
    /// arrives as `NSPOSIXErrorDomain` instead — the same defensive pair `SMBFileSource.mapListError`
    /// already uses.
    static func leavesRequestQueued(_ error: any Error) -> Bool {
        if let posix = error as? POSIXError { return posix.code == .ETIMEDOUT }
        let ns = error as NSError
        return ns.domain == NSPOSIXErrorDomain && ns.code == Int(POSIXErrorCode.ETIMEDOUT.rawValue)
    }

    /// How long a park that nothing will ever settle waits before the graveyard lets go anyway.
    ///
    /// Derived, never typed: `2 × (the operation ceiling + a wide margin)`. Length is not what makes
    /// the release SAFE — see `SMBConnectionGraveyard` for that — it is only about not writing off a
    /// connection that was still going to answer. A NAS spinning up an HDD takes 10–30s, so the fuse
    /// has to sit far past any plausible slow success.
    static func releaseFuse(afterOperationTimeout seconds: TimeInterval) -> Duration {
        // Slack over the operation ceiling before a connection nobody can settle is written off.
        let margin: TimeInterval = 60
        return .seconds(max(0, 2 * (seconds + margin)))
    }
}

/// Where a connection with a pending native call goes to be left alone.
///
/// **THE LAW.** A connection that still has a native operation pending may be neither DISCONNECTED —
/// in any mode, `gracefully: true` included — nor RELEASED. The only safe actions are to park it
/// alive, or to wait until its pending call settles. Three distinct native crash stacks, captured
/// live on a wedged socket, are what fix that as law rather than caution:
///  1. `smb2_read_data` dispatching `query_cb`/`getinfo_cb_2` on the manager's own queue *while*
///     `disconnectShare(gracefully: true)` was running — AMSMB2's graceful teardown races libsmb2's
///     callback dispatch once the socket is wedged with pending requests, so "graceful" is NOT a
///     safe teardown for a pending call, only for a quiet one;
///  2. an in-flight `stat`/`attributesOfItem` crashing as another thread's teardown pulled the
///     context out from under it;
///  3. `SMB2Client.deinit` → `smb2_destroy_context` walking the pending-request list.
///
/// So this type does the only thing left: it holds a STRONG reference and calls nothing. No
/// disconnect, no drain, no probe. When the call settles (`SMBOperationSettlement`), the reference is
/// dropped — and still nothing is disconnected. Plain release is safe exactly then, because stack 3
/// only ever crashed walking PENDING requests and there are none left; and skipping the disconnect
/// PDU is what keeps release from re-entering stack 1 on a socket that is probably dead anyway. The
/// cost of that skip is a session the server tidies up on its own timeout, which is the cheap side of
/// this trade.
///
/// **The bounded park.** Some receipts can never settle: AMSMB2's own reply timeout RETURNS to us
/// while leaving the request queued inside libsmb2, and nothing will ever tell us it retired (see
/// `SMBAbandonedCall`). Parking those forever leaks a TCP connection AND a server-side session per
/// slow operation, which on a NAS with a session cap eventually presents as every browse
/// cold-connecting. So a caller minting such a receipt passes a FUSE, and when it elapses the
/// reference is released — still with no disconnect of any kind.
///
/// Why releasing then is safe, and only then:
///  - the fuse is only ever handed to a park whose Swift call has already RETURNED, so no thread is
///    inside libsmb2 on this context; a release cannot race a live poll loop the way crash stacks 1
///    and 2 did;
///  - and whatever is still queued when the last reference drops is dispatched by
///    `smb2_destroy_context`'s shutdown walk into request-OWNED heap memory (the AMSMB2 patch), not
///    into the stack frame crash stack 3 walked — so nothing dangles, no matter how much libsmb2
///    still holds. That is the whole safety argument: it does not depend on the request being gone
///    by then, only on the memory its callback lands in belonging to the request.
/// A park with a real settlement gets no fuse: its call is still running, and releasing under it is
/// exactly the disposal this type exists to forbid. Those still stay parked indefinitely if their
/// call never returns — one leaked connection per wedge event, the accepted price.
///
/// Owned by `SMBConnectionPool` and reached through `condemn`, but deliberately unaware of pooling:
/// it takes bare connections, so one-shot connections (share enumeration, which never borrows) are
/// condemned by the same primitive as pooled borrows.
actor SMBConnectionGraveyard<Connection: PoolableSMBConnection> {

    /// Parked connections by plot number. Keyed rather than an array because entries are released
    /// out of order (whichever call settles first) and connections are not required to be reference
    /// types, so there is no identity to search by.
    private var plots: [Int: Connection] = [:]
    private var nextPlot = 0
    private var releases = 0

    /// Pending fuses by plot, so a settlement that beats its fuse can cancel it.
    private var fuses: [Int: Task<Void, Never>] = [:]

    /// How a fuse waits out its delay. Injected for the same reason `withHardTimeout`'s `sleep` is:
    /// a test fires a minutes-long fuse instantly instead of sleeping through it.
    private let sleep: @Sendable (Duration) async throws -> Void

    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    /// Dying takes every plot with it — a BULK RELEASE site, since the last reference to each parked
    /// connection goes with the graveyard. Pending fuses are cancelled here so none of them keeps
    /// sleeping toward an actor that no longer exists. Production runs one app-lifetime pool, so
    /// this is documentation of what pool deallocation means rather than a path anything takes.
    deinit {
        for fuse in fuses.values { fuse.cancel() }
    }

    /// Parks `connection` alive until `settlement` reports its pending call has returned, then
    /// releases it WITHOUT disconnecting. Never touches the connection itself.
    ///
    /// - Parameter fuse: for receipts nobody will ever settle only — release the reference after this
    ///   long even without a settlement. See the type comment for why that is safe exactly there.
    func condemn(
        _ connection: Connection,
        settledBy settlement: SMBOperationSettlement,
        releaseAfter fuse: Duration? = nil
    ) {
        let plot = nextPlot
        nextPlot += 1
        plots[plot] = connection
        // Runs inline when the call already settled while the caller was deciding — so the parking
        // and the release cannot deadlock on ordering.
        settlement.whenSettled { [weak self] in
            Task { await self?.release(plot) }
        }
        guard let fuse else { return }
        fuses[plot] = Task { [weak self, sleep] in
            do { try await sleep(fuse) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.releaseOnFuse(plot)
        }
    }

    /// How many connections are parked. Test-visible: "parked, not disconnected" is the whole
    /// contract, and it has no observable side effect to assert on otherwise.
    var occupancy: Int { plots.count }

    /// How many connections have EVER been parked here. `occupancy` alone cannot witness a condemn
    /// whose settlement fires immediately after it (an orphaned cold connect, which settles the
    /// moment its connect call returns) — that one is in and out before anything can look.
    var interments: Int { nextPlot }

    /// How many plots have actually been freed. Test-visible: a settlement and a fuse can both fire
    /// for one plot, and "released exactly once" is otherwise unobservable.
    var releaseCount: Int { releases }

    /// The fuse elapsed with nothing having settled — the only path that lets go of a connection
    /// whose request libsmb2 may still be holding. Named apart from `release` for that reason.
    private func releaseOnFuse(_ plot: Int) {
        release(plot)
    }

    /// Frees one plot, at most once — a fused park can be reached by both its settlement and its
    /// fuse, and the loser must be a no-op rather than a second release.
    private func release(_ plot: Int) {
        fuses.removeValue(forKey: plot)?.cancel()
        // Last-reference drop: ARC deallocates the connection here, and `SMB2Client.deinit` runs its
        // OWN `disconnect()` when the socket still looks connected — so this is a disposal site too.
        guard plots[plot] != nil else { return }
        plots[plot] = nil
        releases += 1
    }
}
