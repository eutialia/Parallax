import AMSMB2
import Foundation
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
/// removed from `idle` (so a concurrent checkout can't re-borrow one mid-teardown).
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
    private static var lanThreshold: Duration { .milliseconds(300) }

    private let connectTimeout: TimeInterval
    private let maxIdlePerKey: Int
    private let idleTTL: Duration
    private let sweepInterval: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let connect: @Sendable (SMBConnectionTarget) async throws -> Connection

    /// Warm, idle connections per key. Each entry stamps the instant it went idle so `reapIdle`
    /// can drop ones past `idleTTL`. Newest is at the end: `checkout` pops the tail (LIFO, keeps the
    /// warmest), the cap and the reaper evict from the front (oldest).
    private var idle: [SMBConnectionKey: [IdleEntry]] = [:]

    /// Latest cold-connect classification per host. `nil` until a host's first cold connect; a warm
    /// reuse records nothing (it did no round trips to time). Latest cold connect wins.
    private var coldLinkClass: [String: SMBLinkClass] = [:]

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
    ///   - connect: builds + connects one share connection for a target. Production wires
    ///     `SMB2Manager` via the convenience `init`; tests inject a fake.
    public init(
        connectTimeout: TimeInterval = 15,
        maxIdlePerKey: Int = 4,
        idleTTL: Duration = .seconds(60),
        sweepInterval: Duration = .seconds(30),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now },
        connect: @escaping @Sendable (SMBConnectionTarget) async throws -> Connection
    ) {
        self.connectTimeout = connectTimeout
        self.maxIdlePerKey = max(1, maxIdlePerKey)
        self.idleTTL = idleTTL
        self.sweepInterval = sweepInterval
        self.now = now
        self.connect = connect
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
    /// A timeout maps to `SMBListerError.timedOut`, and the abandoned connection is simply never
    /// published to the pool (the connector's manager is dropped with the thrown error).
    public func checkout(_ target: SMBConnectionTarget) async throws -> SMBPooledConnection<Connection> {
        startSweepIfNeeded()
        let key = target.key
        await reapIdle(asOf: now())

        if var entries = idle[key], let reused = entries.popLast() {
            idle[key] = entries.isEmpty ? nil : entries
            return SMBPooledConnection(key: key, connection: reused.connection)
        }

        // Cold connect — timed for the link-class signal and bounded by the shared hard timeout.
        let start = now()
        let connection: Connection
        do {
            let connector = connect
            connection = try await withHardTimeout(seconds: connectTimeout + 5) {
                try await connector(target)
            }
        } catch is HardTimeoutError {
            throw SMBListerError.timedOut
        }
        recordColdLatency(host: target.host, elapsed: start.duration(to: now()))
        return SMBPooledConnection(key: key, connection: connection)
    }

    /// Returns a borrowed connection to the idle list, stamped now so the reaper can age it out.
    /// If the key is already at `maxIdlePerKey`, the oldest idle connection is disconnected first —
    /// safe because it is an IDLE entry (zero borrowers), never the one just returned or any live one.
    public func checkin(_ handle: SMBPooledConnection<Connection>) async {
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
            await connection.disconnectGracefully()
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
        let result = await probe.value
        probes[target.host] = nil
        return result
    }

    private func recordProbeFailure(host: String) {
        probeFailures[host] = now()
    }

    /// Discards a borrowed connection instead of returning it to the idle pool — for a borrow that
    /// went WRONG: a reader that saw a thrown read/connect error, or that is being torn down while an
    /// operation may still be in flight (the probe-timeout wedge, where a native AMSMB2 read hasn't
    /// unwound). Returning such a socket to `checkin` would hand a broken/half-consumed session to the
    /// next borrower.
    ///
    /// `nonisolated` and fire-and-forget: it touches no pool state (the connection was already removed
    /// from `idle` at checkout, so simply never re-adding it is the discard) and it must NOT block the
    /// caller's `disconnect()` on a drain that could take the full socket timeout. The graceful
    /// disconnect still runs — draining `operationCount` before libsmb2 destroys the context — so a
    /// still-wedged read completes on the dead socket before teardown (the 76d6fcd use-after-free
    /// guard) rather than being torn out from under.
    public nonisolated func discard(_ handle: SMBPooledConnection<Connection>) {
        Task { await handle.connection.disconnectGracefully() }
    }

    // MARK: - Reaping

    /// Disconnects idle connections older than `idleTTL` as of `instant`. Test-visible so TTL expiry
    /// can be driven off an injected clock without a real 60s wait.
    ///
    /// Removes expired entries from `idle` FIRST (synchronously), then awaits their disconnects — so
    /// the connections being torn down are already unreachable to any reentrant `checkout`, and only
    /// zero-borrower idle connections are ever disconnected (the load-bearing invariant).
    func reapIdle(asOf instant: ContinuousClock.Instant) async {
        var expired: [Connection] = []
        for (key, entries) in idle {
            var kept: [IdleEntry] = []
            for entry in entries {
                if entry.since.duration(to: instant) >= idleTTL {
                    expired.append(entry.connection)
                } else {
                    kept.append(entry)
                }
            }
            idle[key] = kept.isEmpty ? nil : kept
        }
        for connection in expired {
            await connection.disconnectGracefully()
        }
    }

    private func recordColdLatency(host: String, elapsed: Duration) {
        coldLinkClass[host] = elapsed < Self.lanThreshold ? .lan : .wan
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
    public init(
        connectTimeout: TimeInterval = 15,
        maxIdlePerKey: Int = 4,
        idleTTL: Duration = .seconds(60)
    ) {
        self.init(
            connectTimeout: connectTimeout,
            maxIdlePerKey: maxIdlePerKey,
            idleTTL: idleTTL,
            connect: { target in
                guard let client = SMB2Manager(
                    url: target.serverURL, domain: target.domain, credential: target.credential
                ) else {
                    throw SMBListerError.managerInitFailed
                }
                client.timeout = connectTimeout
                try await client.connectShare(name: target.share)
                return client
            }
        )
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
}

extension SMB2Manager: PoolableSMBConnection {
    /// `gracefully: true` waits for the concurrent queue's `operationCount` to drain before
    /// libsmb2 destroys the client context — the crash guard from 76d6fcd. A teardown throw isn't
    /// actionable here (the connection is being discarded anyway), so it's swallowed.
    public func disconnectGracefully() async {
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

    init(key: SMBConnectionKey, connection: Connection) {
        self.key = key
        self.connection = connection
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

    /// Scheme-only connection URL (no userinfo) — the shared `SMBURL.hostOnly` construction,
    /// same as `AMSMB2Lister`.
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
