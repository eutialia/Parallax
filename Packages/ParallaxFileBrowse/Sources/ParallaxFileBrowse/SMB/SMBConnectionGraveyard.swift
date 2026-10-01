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
/// So this type does the only thing left: it holds a STRONG reference and calls nothing WHILE the
/// call runs. No disconnect, no drain, no probe. When the call settles (`SMBOperationSettlement`),
/// the connection gets the same graceful discard as any completed failure (`disconnectGracefully`).
/// That is safe exactly then, for two reasons: the Swift call has RETURNED, so no thread is inside
/// libsmb2 on this context and nothing can race the teardown the way crash stacks 1 and 2 did; and
/// every dispatch a still-queued request gets — a late reply serviced by the disconnect's own poll
/// loop, or the shutdown walk — lands in request-OWNED heap memory (the AMSMB2 patch), not in the
/// stack frame crash stacks 1 and 3 wrote through.
///
/// **Only for calls still RUNNING.** A call that RETURNED — AMSMB2's own reply timeout, which leaves
/// its request queued inside libsmb2, included — is discarded directly, never condemned.
///
/// A park whose call is still RUNNING stays parked until that call returns, and indefinitely if it
/// never does — one leaked connection per wedge event, the accepted price.
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

    /// Parks `connection` alive until `settlement` reports its pending call has returned, then
    /// discards it. Calls nothing on the connection before that.
    func condemn(_ connection: Connection, settledBy settlement: SMBOperationSettlement) {
        let plot = nextPlot
        nextPlot += 1
        plots[plot] = connection
        SMBDiagnostics.graveyard.notice(
            "condemn plot=\(plot) abandoned=\(settlement.isAbandoned) occupancy=\(plots.count)")
        // Runs inline when the call already settled while the caller was deciding — so the parking
        // and the release cannot deadlock on ordering.
        settlement.whenSettled { [weak self] in
            Task { await self?.release(plot) }
        }
    }

    /// How many connections are parked. Test-visible: "parked, not disconnected" is the whole
    /// contract, and it has no observable side effect to assert on otherwise.
    var occupancy: Int { plots.count }

    /// How many connections have EVER been parked here. `occupancy` alone cannot witness a condemn
    /// whose settlement fires immediately after it (an orphaned cold connect, which settles the
    /// moment its connect call returns) — that one is in and out before anything can look.
    var interments: Int { nextPlot }

    /// How many released connections have finished their discard. Test-visible: counted only after
    /// `disconnectGracefully` returns, so a test that sees it has also seen the teardown.
    var releaseCount: Int { releases }

    /// Frees one plot, at most once, through the ordinary graceful discard. Removed from `plots`
    /// before the await, so a second settle signal for the same plot finds nothing to free.
    private func release(_ plot: Int) async {
        guard let connection = plots.removeValue(forKey: plot) else { return }
        SMBDiagnostics.graveyard.notice("→ release plot=\(plot)")
        await connection.disconnectGracefully()
        releases += 1
        // The `←` is only written if that teardown returned. A `→ release` with no `← released` is
        // a teardown that took the process with it.
        SMBDiagnostics.graveyard.notice("← released plot=\(plot) occupancy=\(plots.count)")
    }
}
