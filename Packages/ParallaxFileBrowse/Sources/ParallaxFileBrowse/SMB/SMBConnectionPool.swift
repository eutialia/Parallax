import AMSMB2
import Foundation
import os
import ParallaxCore

/// Cross-fetch reuse of warm SMB share connections, plus a coarse LAN/WAN signal read off
/// cold-connect latency.
///
/// **Why this exists.** Every SMB thumbnail fetch used to stand up a fresh `SMB2Manager` and
/// `connectShare` — 4–6 WAN round trips (TCP, SMB negotiate, session setup, tree connect) paid
/// per tile. On a high-RTT link (SMB over VPN) that connect dominated the whole grab. Pooling
/// keeps a small set of authenticated share connections warm so a scroll through a browse wall
/// reuses them instead of re-handshaking each one.
///
/// **The load-bearing invariant — a pooled connection is only ever disconnected while checked
/// IN (zero live borrowers).** `SMB2Manager`'s work queue is concurrent, and libsmb2 destroys its
/// client context the instant `disconnectShare` runs; tearing a manager down under an in-flight
/// `contents` read is a use-after-free that crashed in libsmb2's `read_cb` (fixed in 76d6fcd by
/// draining before teardown). Pooling must NOT reintroduce that crash class, so every teardown
/// path here — idle-TTL reaping, per-key cap eviction — only ever touches connections sitting in
/// the idle list, which by construction have no borrower. A checked-out connection is unreachable
/// to the reaper until its borrower checks it back in. `checkout` never hands out a connection the
/// same call is about to reap, and `checkin`/`reapIdle` disconnect only entries they have already
/// removed from `idle` (so a concurrent checkout can't re-borrow one mid-teardown). The stronger
/// rule for a connection whose call is still PENDING — never disconnect it, in any mode, and never
/// release it — lives in `SMBConnectionGraveyard`, reached from here through `condemn`.
///
/// **Concurrency.** An `actor`, so the idle map and the link-class table mutate race-free. Teardown
/// awaits happen only on connections already removed from `idle`, so an actor-reentrant `checkout`
/// during a reap can never observe or re-borrow a connection being disconnected.
///
/// **Testability.** The connection is abstracted behind `PoolableSMBConnection` and produced by an
/// injectable `connect` closure; production wires `SMB2Manager` (the convenience `init` below), and
/// tests inject a fake so the reuse / keying / cap / reap / cold-latency / never-destroy-a-borrowed
/// logic is exercised without a network. Wall-clock is injected too (`now`) so a test can simulate
/// a slow connect (advancing a fake clock inside its connector) and TTL expiry without sleeping.
///
/// **Credentials.** The pool key hashes the password (`Data.sha256Hex`, ParallaxCore) — the raw password is
/// never stored in the key nor logged. Folding the digest into the key means a changed credential
/// maps to a FRESH connection instead of silently reusing a session authenticated with the old
/// password. The raw password lives only transiently inside `SMBConnectionTarget` and the
/// `URLCredential` handed to `SMB2Manager`, exactly as `SMBRandomAccessReader` already treats it.
public actor SMBConnectionPool<Connection: PoolableSMBConnection> {

    /// Cold-connect duration below which a host is classed `.lan`. Deliberately COARSE: a LAN
    /// connect settles in tens of ms, while a 130ms-RTT VPN pays 4+ round trips (≈500ms+), so a
    /// single threshold cleanly separates them. This is NOT a speed test and reads nothing about
    /// throughput — it only distinguishes "on the same network" from "across a tunnel" for latency-
    /// sensitive policy (e.g. how aggressively to prefetch).
    ///
    /// Package-internal so the classification tests straddle THIS value rather than re-typing
    /// latencies that a retune would silently invert.
    static var lanThreshold: Duration { .milliseconds(300) }

    /// Slack added to `connectTimeout` for the cold-connect `withHardTimeout` ceiling: AMSMB2 bounds
    /// SMB PDU responses itself, so this outer race only has to catch the phases it doesn't cover
    /// (name resolution in particular) — it should fire only when the inner timeout has already
    /// failed to. Package-internal so a test can derive a sub-second ceiling from it.
    static var hardTimeoutGrace: TimeInterval { 5 }

    private let connectTimeout: TimeInterval
    private let maxIdlePerKey: Int
    private let idleTTL: Duration
    private let sweepInterval: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let connect: SMBConnectionBuilder<Connection>

    /// Warm, idle connections per key. Each entry stamps the instant it went idle so `reapIdle`
    /// can drop ones past `idleTTL`. Newest is at the end: `checkout` pops the tail (LIFO, keeps the
    /// warmest), the cap and the reaper evict from the front (oldest).
    private var idle: [SMBConnectionKey: [IdleEntry]] = [:]

    /// Latest cold-connect classification per host. `nil` until a host's first cold connect; a warm
    /// reuse records nothing (it did no round trips to time). See `recordColdLatency` for which
    /// samples are allowed to change it.
    private var coldLinkClass: [String: SMBLinkClass] = [:]

    /// Consecutive SLOW cold samples per host, reset by any fast one. Feeds the demotion hysteresis
    /// in `recordColdLatency`; the entry is removed (never kept at zero) once a fast sample lands.
    private var consecutiveSlowColds: [String: Int] = [:]

    /// Bumped by `flushIdle`. Every borrow is stamped with the epoch it was taken under, and a
    /// check-in from an older epoch is disposed instead of pooled — see `checkin`.
    private var flushEpoch = 0

    /// One in-flight classification probe per host — concurrent `ensureLinkClass` callers coalesce
    /// onto it instead of each cold-connecting.
    private var probes: [String: Task<SMBLinkClass?, Never>] = [:]
    /// When a host's last classification probe FAILED, so a dead host is re-probed once per backoff
    /// window rather than once per prefetch batch.
    private var probeFailures: [String: ContinuousClock.Instant] = [:]
    private static var probeFailureBackoff: Duration { .seconds(60) }

    /// The scheduled idle sweep, started lazily on first `checkout` (a never-used pool spawns no
    /// task). Reaps opportunistically on every checkout/checkin too — the sweep only bounds a pool
    /// that went quiet with connections still warm.
    private var sweepTask: Task<Void, Never>?

    /// Where connections with a pending native call are parked (see `condemn`). Per-pool rather than
    /// process-wide so a pool's condemned set dies with it — and so tests never share one.
    private let graveyard: SMBConnectionGraveyard<Connection>

    private struct IdleEntry {
        let connection: Connection
        let since: ContinuousClock.Instant
    }

    /// - Parameters:
    ///   - connectTimeout: per-operation ceiling handed to the connector (and the wall-clock bound
    ///     below). Matches `SMBRandomAccessReader`'s 15s default.
    ///   - maxIdlePerKey: how many warm connections to retain per key. Beyond this, `checkin`
    ///     disconnects the oldest. 4 covers a scrolling grid's overlap without hoarding sessions.
    ///   - idleTTL: a connection idle longer than this is disconnected by the reaper (~60s).
    ///   - sweepInterval: cadence of the background reap (real time; opportunistic reaps cover the rest).
    ///   - now: wall-clock source, injectable for deterministic tests.
    ///   - connect: builds + connects one share connection for a target, handing the built
    ///     connection to `deliver` before the share attach — see `SMBConnectionBuilder`. Production
    ///     wires `SMB2Manager` via the convenience `init`; tests inject a fake.
    ///   - fuseSleep: how a graveyard release fuse waits (see `condemn`). Injectable so a test can
    ///     fire a minutes-long fuse instantly.
    public init(
        connectTimeout: TimeInterval = 15,
        maxIdlePerKey: Int = 4,
        idleTTL: Duration = .seconds(60),
        sweepInterval: Duration = .seconds(30),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now },
        connect: @escaping SMBConnectionBuilder<Connection>,
        fuseSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.connectTimeout = connectTimeout
        self.maxIdlePerKey = max(1, maxIdlePerKey)
        self.idleTTL = idleTTL
        self.sweepInterval = sweepInterval
        self.now = now
        self.connect = connect
        self.graveyard = SMBConnectionGraveyard<Connection>(sleep: fuseSleep)
    }

    deinit {
        sweepTask?.cancel()
    }

    /// Hands out a connected share connection for `target`: a warm idle one for the key when
    /// available (no round trips), else a fresh cold connect. Never blocks waiting for a borrower to
    /// return — if nothing is idle it connects. The returned handle must be returned via `checkin`.
    ///
    /// The cold connect is bounded by the same fast-fail discipline the rest of the SMB layer uses:
    /// `withHardTimeout` (commit b0027a3), reused rather than re-rolled, so a dead host fails in
    /// `connectTimeout` + grace instead of hanging in a phase AMSMB2's own timeout doesn't cover.
    /// A timeout maps to `SMBListerError.timedOut` and every other failure surfaces as it is — but
    /// NO failure exit drops the connector's manager: whatever it built is claimed by
    /// `claimAbandonedConnect`.
    ///
    /// - Parameter requireFresh: skip the idle list and cold-connect, AND discard the key's current
    ///   idle entries. For a borrower that has just proven the warm connections for this key are
    ///   dead — after device sleep every pooled socket is stale, so the siblings pooled beside the
    ///   corpse it just used are corpses too, and a later borrow of one tells the user nothing new.
    public func checkout(
        _ target: SMBConnectionTarget,
        requireFresh: Bool = false
    ) async throws -> SMBPooledConnection<Connection> {
        startSweepIfNeeded()
        let key = target.key
        await reapIdle(asOf: now())

        if requireFresh {
            // Purged in this same actor-isolated step, before anything is torn down: they are idle
            // entries with zero borrowers (the teardown rule is untouched), and leaving them would
            // just hand the next borrower another corpse. Detached, like every other eviction.
            let corpses = (idle.removeValue(forKey: key) ?? []).map(\.connection)
            for connection in corpses { Task { await connection.disconnectGracefully() } }
        } else if var entries = idle[key], let reused = entries.popLast() {
            idle[key] = entries.isEmpty ? nil : entries
            return SMBPooledConnection(
                key: key, connection: reused.connection, isWarm: true, epoch: flushEpoch)
        }

        // Cold connect — timed for the link-class signal and bounded by the shared hard timeout.
        let start = now()
        let connection: Connection
        // The connector keeps running after we give up (`withHardTimeout` never cancels it), and it
        // hands its connection over the moment it exists (see `SMBConnectionBuilder`), so anything
        // it built has an owner however the attempt ends. The settlement says when its connect call
        // actually returned.
        let escrow = SMBConnectionEscrow<Connection>()
        let settlement = SMBOperationSettlement()
        do {
            let connector = connect
            connection = try await withHardTimeout(
                seconds: connectTimeout + Self.hardTimeoutGrace,
                settlement: settlement
            ) {
                try await connector(target) { escrow.deliver($0) }
            }
        } catch {
            claimAbandonedConnect(
                escrow, failedWith: error, settlement: settlement, operationTimeout: connectTimeout
            )
            if error is HardTimeoutError { throw SMBListerError.timedOut }
            throw error
        }
        recordColdLatency(host: target.host, elapsed: start.duration(to: now()))
        // Stamped AFTER the connect: a flush that happened while this handshake was in flight
        // targeted the sockets that existed before it, not this brand-new one.
        return SMBPooledConnection(
            key: key, connection: connection, isWarm: false, epoch: flushEpoch)
    }

    /// Takes ownership of whatever a failed connect managed to build, so no abandonment ever leaves
    /// a connection for ARC to release.
    ///
    /// The loser's manager used to be dropped on the floor — and `SMB2Client.deinit` runs its own
    /// `disconnect()` plus `smb2_destroy_context`, i.e. the exact disposal the graveyard forbids for
    /// a connection whose call may still be pending. Every failure exit hands it over instead:
    /// parked alive, never disconnected. How long it stays parked is what the error decides:
    ///  - ABANDONED (the hard ceiling fired, or the caller was cancelled) — the call is still
    ///    running, so the receipt is a real one and the park ends when that call returns;
    ///  - AMSMB2's own reply timeout — the call returned but left a request queued inside libsmb2,
    ///    and nothing will ever settle the receipt, so the park carries a FUSE (`SMBAbandonedCall`);
    ///  - anything else — the call returned and left nothing behind, so the receipt is settled here
    ///    and the park frees as soon as it is made. Routing it through the graveyard anyway keeps
    ///    ONE disposal path for a connection nobody owns.
    ///
    /// The escrow may hold nothing at all: a connector that failed before it constructed anything
    /// delivered nothing, and the claim simply never fires.
    ///
    /// `nonisolated` because share enumeration (`PooledSMBLister.listShares`) builds its own
    /// connection outside the pool and needs the identical claim on its own connect failure.
    nonisolated func claimAbandonedConnect(
        _ escrow: SMBConnectionEscrow<Connection>,
        failedWith error: any Error,
        settlement: SMBOperationSettlement,
        operationTimeout: TimeInterval
    ) {
        let fuse: Duration? = SMBAbandonedCall.leavesRequestQueued(error)
            ? SMBAbandonedCall.releaseFuse(afterOperationTimeout: operationTimeout)
            : nil
        // Not abandoned and nothing queued ⇒ the connect call has returned for good, so the receipt
        // is already true: mark it, and the park below releases the instant it is made.
        if fuse == nil, !settlement.isAbandoned { settlement.markSettled() }
        escrow.onDelivery { [graveyard] built in
            Task { await graveyard.condemn(built, settledBy: settlement, releaseAfter: fuse) }
        }
    }

    /// Returns a borrowed connection to the idle list, stamped now so the reaper can age it out.
    /// If the key is already at `maxIdlePerKey`, the oldest idle connection is disconnected first —
    /// safe because it is an IDLE entry (zero borrowers), never the one just returned or any live one.
    ///
    /// The evictions run DETACHED (like `discard`): a tree-disconnect + logoff is two round trips on
    /// a real NAS, and no caller returning a connection should be charged for pool hygiene. The
    /// eviction is still decided synchronously and the entry is out of `idle` before any teardown
    /// starts, so the "only ever disconnect a zero-borrower idle connection" invariant is untouched.
    ///
    /// A borrow taken BEFORE the latest `flushIdle` is disposed rather than pooled: the flush's
    /// whole premise is that every socket predating it died in device sleep, and a long-running
    /// borrow (a thumbnail reader holds one for tens of seconds) checking in after the wake would
    /// otherwise re-seed the freshly emptied idle map with exactly the corpse the flush removed.
    public func checkin(_ handle: SMBPooledConnection<Connection>) async {
        guard handle.epoch >= flushEpoch else {
            // Detached, like every other teardown here: the borrower pays nothing for pool hygiene.
            Task { await handle.connection.disconnectGracefully() }
            return
        }
        await reapIdle(asOf: now())

        var entries = idle[handle.key] ?? []
        entries.append(IdleEntry(connection: handle.connection, since: now()))

        // Cap: evict the oldest (front) beyond the ceiling. Remove from `idle` BEFORE awaiting the
        // disconnect so a reentrant checkout can never re-borrow a connection mid-teardown.
        var overflow: [Connection] = []
        if entries.count > maxIdlePerKey {
            let excess = entries.count - maxIdlePerKey
            overflow = entries.prefix(excess).map(\.connection)
            entries.removeFirst(excess)
        }
        idle[handle.key] = entries

        for connection in overflow {
            Task { await connection.disconnectGracefully() }
        }
    }

    /// The coarse link class last observed for `host`, or nil before any cold connect to it.
    /// See `lanThreshold` — a deliberate one-shot heuristic, not a throughput measurement.
    public func linkClass(host: String) -> SMBLinkClass? {
        coldLinkClass[host]
    }

    /// The link class for `target`'s host, performing one cold connect to MEASURE it when no
    /// generation has connected yet. The probe connection is checked straight back in, so it doubles
    /// as pool warm-up: the first real fetch reuses it instead of paying its own handshake.
    ///
    /// Exists for batch schedulers that bake a link class per work item at SCHEDULE time (the
    /// thumbnail prefetcher): without an up-front classification, an entire first batch reads nil —
    /// conservatively WAN-serialised — and a LAN host never sees its measured concurrency until the
    /// batch after. Returns nil when the probe itself fails (host down, bad credentials); callers
    /// treat that as unknown and stay conservative.
    ///
    /// COALESCED: concurrent callers for one host await a single in-flight probe instead of each
    /// paying a cold connect — without this, a fling through a fresh folder fires many prefetch
    /// batches that would all probe simultaneously, and on a dead host each would hang the full
    /// connect ceiling (the exact per-tile handshake storm the pool exists to eliminate). A FAILED
    /// probe is memoised for `probeFailureBackoff` so a dead host is re-probed once per window,
    /// not once per batch.
    public func ensureLinkClass(_ target: SMBConnectionTarget) async -> SMBLinkClass? {
        if let known = coldLinkClass[target.host] { return known }
        if let inFlight = probes[target.host] { return await inFlight.value }
        if let failedAt = probeFailures[target.host],
           failedAt.duration(to: now()) < Self.probeFailureBackoff {
            return nil
        }

        let probe = Task { [weak self] () -> SMBLinkClass? in
            guard let self else { return nil }
            guard let borrowed = try? await self.checkout(target) else {
                await self.recordProbeFailure(host: target.host)
                return nil
            }
            await self.checkin(borrowed)
            return await self.linkClass(host: target.host)
        }
        probes[target.host] = probe
        // Cleared on EVERY exit: an awaiter that goes away mid-probe would otherwise strand the
        // entry, and every later caller for this host would coalesce onto a task nobody drives.
        defer { probes[target.host] = nil }
        return await probe.value
    }

    private func recordProbeFailure(host: String) {
        probeFailures[host] = now()
    }

    /// Discards a borrowed connection instead of returning it to the idle pool — for a borrow whose
    /// operation COMPLETED but went wrong: a thrown read/listing error, or a session disqualified from
    /// reuse. The socket may be half-consumed or degraded, so `checkin` would hand the next borrower
    /// somebody else's failure. The connection is disconnected gracefully in the background.
    ///
    /// **Only for completed operations.** A borrow whose native call is still PENDING must go to
    /// `condemn` instead — see the law in `SMBConnectionGraveyard`: a graceful disconnect races
    /// libsmb2's callback dispatch on a wedged socket and crashes. This path stays exactly as it was
    /// because it is production-proven for the case it now exclusively serves: the call already
    /// returned, so the drain it performs finds nothing to wait for.
    ///
    /// `nonisolated` and fire-and-forget: it touches no pool state (the connection was already removed
    /// from `idle` at checkout, so simply never re-adding it is the discard) and it must NOT block the
    /// caller's `disconnect()` on a teardown that could take the full socket timeout.
    public nonisolated func discard(_ handle: SMBPooledConnection<Connection>) {
        Task { await handle.connection.disconnectGracefully() }
    }

    /// Parks a borrow whose native call is STILL PENDING: no disconnect of any kind, and no release
    /// until `settlement` reports the call has returned. The law and its costs live on
    /// `SMBConnectionGraveyard`; this is the pool-side door to it.
    ///
    /// Pool bookkeeping needs no unwinding: `checkout` already removed the connection from `idle`, so
    /// never re-adding it is the whole eviction — the key is free to cold-connect a replacement the
    /// moment the next borrower asks. Unlike `discard`, this is actor-isolated and awaited: parking a
    /// reference touches no socket, so there is nothing here that could stall a caller.
    ///
    /// `fuse` bounds a park that nothing will ever settle — see `SMBConnectionGraveyard.condemn`.
    func condemn(
        _ handle: SMBPooledConnection<Connection>,
        settlement: SMBOperationSettlement,
        releaseAfter fuse: Duration? = nil
    ) async {
        await condemn(handle.connection, settlement: settlement, releaseAfter: fuse)
    }

    /// The same parking for a connection that was never borrowed — share enumeration builds its own
    /// one-shot connection, and a wedged call on it is the identical hazard.
    func condemn(
        _ connection: Connection,
        settlement: SMBOperationSettlement,
        releaseAfter fuse: Duration? = nil
    ) async {
        await graveyard.condemn(connection, settledBy: settlement, releaseAfter: fuse)
    }

    /// How many connections are currently parked in the graveyard. Test-visible only: condemning is
    /// defined by what it does NOT do, so its bookkeeping is the only positive evidence it happened.
    var condemnedCount: Int {
        get async { await graveyard.occupancy }
    }

    /// How many connections this pool has condemned in total. Test-visible for the condemns that
    /// settle immediately — see `SMBConnectionGraveyard.interments`.
    var condemnedTotal: Int {
        get async { await graveyard.interments }
    }

    /// How many parked connections have actually been let go. Test-visible: a fused park can be
    /// reached by BOTH its settlement and its fuse, and "released exactly once" has no other witness.
    var releasedTotal: Int {
        get async { await graveyard.releaseCount }
    }

    /// How many warm connections are sitting idle across all keys. Test-visible: check-in is now
    /// detached on the listing path, so a test that needs a borrow to have LANDED has nothing else
    /// to poll (its only other symptom is the absence of a cold connect, which races).
    var idleCount: Int {
        idle.values.reduce(0) { $0 + $1.count }
    }

    // MARK: - Reaping

    /// Disconnects idle connections older than `idleTTL` as of `instant`, EXCEPT a key's last one.
    /// Test-visible so TTL expiry can be driven off an injected clock without a real 60s wait.
    ///
    /// **A key always keeps one warm connection.** Thumbnail readers hold their borrows for tens of
    /// seconds and re-borrow continuously, so the browse listing's connection is the only one that
    /// ever sits idle long enough to age out — TTL-reaping it made every drill into a subfolder pay a
    /// fresh handshake while the pool still held live connections to the same share. The survivor
    /// still dies with the pool, on discard/condemn, by cap eviction (which only fires when a NEWER
    /// connection has already replaced it), or when a borrower proves the key dead and checks out
    /// with `requireFresh` — so nothing here can hoard sessions.
    ///
    /// Only the LISTING path retries onto a fresh connection when it is handed a corpse
    /// (`PooledSMBLister.list`); the reader path deliberately does not, because a thumbnail that
    /// fails soft costs a placeholder while a folder that fails hard costs an error scrim.
    ///
    /// Removes expired entries from `idle` FIRST (synchronously), then disconnects them — so the
    /// connections being torn down are already unreachable to any reentrant `checkout`, and only
    /// zero-borrower idle connections are ever disconnected (the load-bearing invariant). The
    /// disconnects run DETACHED and therefore concurrently: they are round trips on a real NAS, and
    /// serialising them charged the whole sweep to whoever happened to trigger it.
    func reapIdle(asOf instant: ContinuousClock.Instant) async {
        var expired: [Connection] = []
        for (key, entries) in idle {
            var kept: [IdleEntry] = []
            var reaped: [IdleEntry] = []
            for entry in entries {
                if entry.since.duration(to: instant) >= idleTTL {
                    reaped.append(entry)
                } else {
                    kept.append(entry)
                }
            }
            // Entries run oldest → newest, so the last reaped one is the warmest: keep that one when
            // the key would otherwise be left with nothing.
            if kept.isEmpty, let survivor = reaped.popLast() {
                kept.append(survivor)
            }
            idle[key] = kept.isEmpty ? nil : kept
            expired.append(contentsOf: reaped.map(\.connection))
        }
        for connection in expired {
            Task { await connection.disconnectGracefully() }
        }
    }

    /// Drops every idle connection across the whole pool — no per-key survivor.
    ///
    /// Called on foreground reactivation after device sleep: the OS has almost certainly killed
    /// every socket while the app was suspended, so every warm idle entry is a corpse. Unlike
    /// `reapIdle` (which deliberately keeps each key's last warm connection so the next drill-in
    /// is handshake-free), a post-sleep "survivor" is just another dead socket and must go too —
    /// the same reasoning as `checkout(requireFresh:)`'s whole-key purge, applied pool-wide.
    ///
    /// Does not touch condemned connections (graveyard), link-class caches, or latency probes, and
    /// never disconnects a checked-out connection (it is not in `idle`) — but it does mark those
    /// borrows: bumping the epoch means their `checkin` disposes them instead of pooling them, so a
    /// borrow that predates the sleep can't re-fill the map the flush just emptied. Removes every
    /// idle entry FIRST (synchronously, before any suspension), then tears each down in a detached
    /// `Task` — the same removes-then-tears-down idiom as `reapIdle` / the `requireFresh` branch, so
    /// a reentrant `checkout` can never re-borrow a connection mid-teardown.
    public func flushIdle() async {
        flushEpoch += 1
        let corpses = idle.values.flatMap { $0.map(\.connection) }
        idle.removeAll()
        for connection in corpses {
            Task { await connection.disconnectGracefully() }
        }
    }

    /// Folds one cold-connect measurement into `host`'s class, with HYSTERESIS on the way down.
    ///
    /// Promotion is instant: a fast cold connect proves the host is local, and nothing about a
    /// stale `.wan` label is worth keeping against that. Demotion needs TWO consecutive slow
    /// samples, because the moments that produce a single slow one are exactly the moments a LAN
    /// host looks worst — a post-wake flush forces a cold connect while the radio is still
    /// re-associating and the NAS disks are spinning up. One such sample used to pin the host `.wan`
    /// for the rest of the session (once a warm survivor exists, nothing re-measures), and that
    /// label then narrowed the thumbnail admission window to 1 and disabled the backfill's
    /// LAN-only capture.
    private func recordColdLatency(host: String, elapsed: Duration) {
        guard elapsed >= Self.lanThreshold else {
            consecutiveSlowColds[host] = nil
            coldLinkClass[host] = .lan
            return
        }
        let slowRun = (consecutiveSlowColds[host] ?? 0) + 1
        consecutiveSlowColds[host] = slowRun
        // First slow sample against a host already measured `.lan` is treated as a blip; anything
        // else (unclassified host, already `.wan`, or a second slow sample in a row) classes `.wan`.
        let isFirstBlipOnALANHost = coldLinkClass[host] == .lan && slowRun < 2
        if !isFirstBlipOnALANHost {
            coldLinkClass[host] = .wan
        }
    }

    private func startSweepIfNeeded() {
        guard sweepTask == nil else { return }
        let interval = sweepInterval
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await self.reapIdle(asOf: self.now())
            }
        }
    }
}

// MARK: - Convenience: SMB2Manager-backed pool

/// The production pool specialization: a pool of real `SMB2Manager` share connections. Aliased so
/// app-side owners (`AppDependencies`, `MediaArtworkProvider`, `SMBPlaybackResolver`) can name and
/// construct the pool WITHOUT importing AMSMB2 — `SMB2Manager` stays an implementation detail behind
/// this package. The concrete `SMBRandomAccessReader` pooled init takes this exact specialization.
public typealias SMBSharePool = SMBConnectionPool<SMB2Manager>

extension SMBConnectionPool where Connection == SMB2Manager {

    /// Production pool: the connector builds and `connectShare`s a real `SMB2Manager`, its
    /// per-operation `timeout` pinned to `connectTimeout` (the SMB-login fast-fail ceiling). The
    /// pool's own `withHardTimeout` bound wraps this call, so a connect that wedges in a phase
    /// AMSMB2 never bounds still fails fast.
    ///
    /// Make-then-attach: the manager is delivered BEFORE `connectShare`, so a share attach that
    /// times out (AMSMB2's reply timeout leaves the request queued) still has an owner for it.
    public init(
        connectTimeout: TimeInterval = 15,
        maxIdlePerKey: Int = 4,
        idleTTL: Duration = .seconds(60)
    ) {
        self.init(
            connectTimeout: connectTimeout,
            maxIdlePerKey: maxIdlePerKey,
            idleTTL: idleTTL,
            connect: { target, deliver in
                guard let client = SMB2Manager(
                    url: target.serverURL, domain: target.domain, credential: target.credential
                ) else {
                    throw SMBListerError.managerInitFailed
                }
                client.timeout = connectTimeout
                deliver(client)
                try await client.connectShare(name: target.share)
                return client
            }
        )
    }
}

// MARK: - The connector contract

/// How one SMB connection is built for the pool (and for share enumeration, which owns its own):
/// MAKE it, hand it to `deliver` immediately, and only THEN attach the share.
///
/// Delivering first is the whole point. Everything past construction can throw or be abandoned — a
/// share attach that hits AMSMB2's reply timeout, a hard ceiling firing over a wedged connect, a
/// cancelled caller — and each of those leaves a live connection that whoever asked for it is no
/// longer waiting on. Handing it over the moment it exists means it always has an owner instead of
/// being released by ARC under a native call that may still be running (`SMB2Client.deinit` →
/// `smb2_destroy_context`, the disposal `SMBConnectionGraveyard` forbids).
public typealias SMBConnectionBuilder<Connection: Sendable> =
    @Sendable (_ target: SMBConnectionTarget, _ deliver: @Sendable (Connection) -> Void) async throws -> Connection

// MARK: - Escrow for a connection nobody is waiting for any more

/// A one-slot handover for a connection whose builder failed or was abandoned. The connector cannot
/// be cancelled, so it finishes on its own schedule; this catches what it produces so the connection
/// has an owner instead of being released by ARC under a native call that may still be running (the
/// `SMB2Client.deinit` → `smb2_destroy_context` disposal).
///
/// Order-independent, like `SMBOperationSettlement`: the connection may arrive before or after
/// anyone claims it, and either way the claim runs exactly once.
final class SMBConnectionEscrow<Connection: Sendable>: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var delivered: Connection?
        var claim: (@Sendable (Connection) -> Void)?
    }

    /// Hands over a freshly built connection — called by the connector as soon as it exists, before
    /// the share attach that may fail. An unclaimed delivery is simply dropped when the escrow dies,
    /// which is what the successful path wants: the caller already owns the connection.
    func deliver(_ connection: Connection) {
        let claim: (@Sendable (Connection) -> Void)? = state.withLock { state in
            state.delivered = connection
            defer { state.claim = nil }
            return state.claim
        }
        claim?(connection)
    }

    /// Registers who takes the connection — immediately if it already arrived.
    func onDelivery(_ claim: @escaping @Sendable (Connection) -> Void) {
        let alreadyHere: Connection? = state.withLock { state in
            guard state.delivered == nil else { return state.delivered }
            state.claim = claim
            return nil
        }
        if let alreadyHere { claim(alreadyHere) }
    }
}

// MARK: - Connection abstraction

/// A live SMB share connection the pool can retain and, when idle, tear down. Abstracted so the
/// pool's lifecycle logic is unit-testable without a network. Production conforms `SMB2Manager`;
/// tests conform a fake. `disconnectGracefully()` MUST drain in-flight work before destroying the
/// underlying context — the pool only ever calls it on zero-borrower idle connections, but the
/// graceful contract is the second line of defense against the libsmb2 use-after-free (76d6fcd).
public protocol PoolableSMBConnection: Sendable {
    func disconnectGracefully() async

    /// Pins the per-operation response ceiling. A pool concern, even though the pool never calls it
    /// itself: warm reuse inherits the PREVIOUS borrower's value, so every borrower re-asserts its
    /// own right after checkout.
    func setOperationTimeout(_ seconds: TimeInterval)
}

extension SMB2Manager: PoolableSMBConnection {
    public func setOperationTimeout(_ seconds: TimeInterval) {
        timeout = seconds
    }

    /// `gracefully: true` waits for the concurrent queue's `operationCount` to drain before
    /// libsmb2 destroys the client context — the crash guard from 76d6fcd. A teardown throw isn't
    /// actionable here (the connection is being discarded anyway), so it's swallowed.
    public func disconnectGracefully() async {
        // THE choke point: every real `disconnectShare` in the app funnels through here.
        try? await disconnectShare(gracefully: true)
    }
}

// MARK: - Handle & key

/// A checked-out connection plus the key it belongs to. Opaque to callers except the underlying
/// `connection`, which the borrower (e.g. `SMBRandomAccessReader`) reads to issue SMB operations.
/// Returned to the pool via `checkin`. Not manually constructible outside the pool.
public struct SMBPooledConnection<Connection: PoolableSMBConnection>: Sendable {
    let key: SMBConnectionKey
    let connection: Connection

    /// Whether this borrow came out of the idle list rather than off a fresh handshake. A borrower
    /// reads it to tell "the pool handed me a stale socket" from "the server is actually
    /// unreachable" — only the first is worth one retry (see `PooledSMBLister.list`).
    let isWarm: Bool

    /// The pool's flush epoch when this borrow was taken. `checkin` compares it against the current
    /// one so a borrow that predates a `flushIdle` is disposed rather than pooled.
    let epoch: Int

    init(key: SMBConnectionKey, connection: Connection, isWarm: Bool, epoch: Int) {
        self.key = key
        self.connection = connection
        self.isWarm = isWarm
        self.epoch = epoch
    }
}

/// The identity a pooled connection is keyed by: host + domain + user + share + a SHA256 digest of
/// the password. Hashing the password (never storing it raw) means a credential change lands on a
/// fresh key — the pool can't reuse a session authenticated with the old password. Internal: an
/// implementation detail of pooling, derived from a `SMBConnectionTarget`.
struct SMBConnectionKey: Hashable, Sendable {
    let host: String
    let domain: String
    let username: String
    let share: String
    let passwordDigest: String
}

/// Everything needed to (re)connect one SMB share, including the raw password required to build the
/// `URLCredential`. The password lives only here and in the `URLCredential` — never in the pool key
/// (which carries only its digest) and never logged. Mirrors `SMBRandomAccessReader`'s init: the
/// scheme-only, userinfo-free host URL, the percent-encoded host so a spaced Bonjour name still
/// resolves, and the NT domain routed to AMSMB2's dedicated `domain:` parameter.
public struct SMBConnectionTarget: Sendable {
    public let host: String
    public let username: String
    public let password: String
    public let domain: String
    public let share: String

    public init(host: String, username: String, password: String, domain: String = "", share: String) {
        self.host = host
        self.username = username
        self.password = password
        self.domain = domain
        self.share = share
    }

    /// The same target built from an `SMBCredentials` value. Preferred wherever the account travels
    /// as a unit, so the four interchangeable credential strings are never re-typed positionally.
    public init(credentials: SMBCredentials, share: String) {
        self.init(
            host: credentials.host,
            username: credentials.username,
            password: credentials.password,
            domain: credentials.domain,
            share: share
        )
    }

    /// Scheme-only connection URL (no userinfo) — the shared `SMBURL.hostOnly` construction.
    var serverURL: URL {
        SMBURL.hostOnly(host)
    }

    /// Session-scoped credential handed to `SMB2Manager`. The domain is passed via AMSMB2's dedicated
    /// `domain:` init parameter, NOT folded into the user field (a `DOMAIN\user` string maps to the
    /// NTLM workstation field in libsmb2, not the domain — verified against AMSMB2 4.0.3).
    var credential: URLCredential {
        URLCredential(user: username, password: password, persistence: .forSession)
    }

    /// The pooling key. The password is reduced to a SHA256 hex digest (`Data.sha256Hex`,
    /// ParallaxCore) so the raw secret never enters the key (nor any log that prints one).
    var key: SMBConnectionKey {
        SMBConnectionKey(
            host: host, domain: domain, username: username, share: share,
            passwordDigest: Data(password.utf8).sha256Hex
        )
    }
}

/// A coarse classification of the path to an SMB host, derived from cold-connect latency. Feeds
/// latency-sensitive policy (prefetch aggressiveness), NOT throughput decisions — it is not a speed
/// test. See `SMBConnectionPool.lanThreshold`.
public enum SMBLinkClass: Sendable, Equatable {
    /// Cold connect settled quickly (< the LAN threshold) — same network as the host.
    case lan
    /// Cold connect was slow — the host is across a tunnel / high-RTT link.
    case wan
}
