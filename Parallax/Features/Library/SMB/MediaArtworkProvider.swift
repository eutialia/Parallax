import Foundation
import OSLog
import ParallaxCore
import ParallaxFileBrowse
import ParallaxJellyfin
import ParallaxPlayback

/// A resolved tile artwork plus the source duration extracted while generating it. The duration
/// rides alongside the image so an SMB tile can show its runtime under the thumbnail; nil when the
/// source carries no artwork or libvlc couldn't read a length.
struct MediaArtwork: Sendable, Equatable {
    let source: ArtworkSource
    let duration: Duration?

    static let none = MediaArtwork(source: .none, duration: nil)
}

/// Resolves a poster for a source-neutral `Item` that carries no server artwork — today only the
/// SMB path, which generates a frame-grab from the video itself.
///
/// Owns the whole generation pipeline so the call site (a grid tile's `.task`) stays trivial:
///   disk-cache hit (instant) → negative-cache skip (instant) → gated generation on a real miss.
///
/// **Why an actor in front of the cache.** `SMBThumbnailCache` is a pure disk layer; it has no
/// concurrency limit and no failure memory. This provider adds the three things a NAS needs:
/// a single-permit gate (measured 2026-07-10: fetches are BANDWIDTH-bound over VPN — each
/// moves 7–17 MB and two in flight split the link, pushing both past the timeout, where a
/// timeout throws its whole download away; serial fetches finish each item ~2× sooner at the
/// same aggregate rate, so one permit is strictly better goodput); coalescing (a re-check of
/// the disk after acquiring the permit, so two tasks racing for the same key don't both demux
/// it); and an in-memory negative cache so a permanently undecodable file isn't re-attempted
/// (and re-charged the full timeout) on every scroll-past.
///
/// **Credentials** never leave this file in the clear: they're read from the Keychain via
/// `SMBSourceResolver` and ride `vlcOptions` into `VLCThumbnailer`, which never logs them.
actor MediaArtworkProvider {

    /// Per-fetch outcome diagnostics. File NAMES only (never credentials, never full URLs);
    /// matches the `SMBRandomAccessReader` path-logging precedent.
    private static let log = Logger(subsystem: "com.lhdev.parallax", category: "thumbnails")

    private let cache: SMBThumbnailCache
    /// `@MainActor`-isolated; constructed on the main actor in `AppDependencies` and called via
    /// `await` (it hops to main for the actual decode).
    private let thumbnailer: VLCThumbnailer
    private let serverStore: ServerStore

    /// One permit — see the type doc. A 2-permit round (2026-07-10) was MEASURED WORSE over
    /// VPN: per-fetch bridge stats showed bandwidth contention (lockstep ~30s timeouts, each
    /// wasting its full 10+ MB download). Don't widen again without per-fetch stats proving
    /// the link isn't the bottleneck.
    private let gate = ThumbnailGate()

    /// Hard ceiling per generation (pre-parse + fetch share it). 30s, not the thumbnailer's 20s
    /// default: over VPN a *successful* fetch measured 11.1s and several legitimate files timed
    /// out at 20s, so the default ceiling sat inside the observed success band. On LAN a fetch
    /// takes 1–3s, so only genuinely broken files ever pay this — and they're then poisoned for
    /// `failureBackoff` anyway.
    private static let generationTimeout: Duration = .seconds(30)

    /// Keys whose generation recently failed, with when. In-memory only: a relaunch clears it so a
    /// transient NAS outage self-heals. Entries self-expire on the next lookup past the backoff.
    private var failures: [SMBThumbnailKey: ContinuousClock.Instant] = [:]
    private let clock = ContinuousClock()
    private static let failureBackoff: Duration = .seconds(180)

    /// True while a player session owns the screen (driven by `RootView` from
    /// `PlaybackPresenter.isPlayerPresent`). Generation HOLDS while set: the full-screen player
    /// covers the grid without cancelling its cells' `.task`s, so without this the frame-grab
    /// pipeline keeps streaming SMB bytes over the same uplink the player is using (worst over
    /// VPN). Cache hits and negative-cache skips still return instantly — only demux waits.
    private var playbackActive = false
    private var playbackWaiters = WaiterList()
    /// Highest presence-edge token applied so far — see `setPlaybackActive(_:seq:)`.
    private var lastPlaybackSeq = 0

    init(
        thumbnailer: VLCThumbnailer,
        serverStore: ServerStore,
        cache: SMBThumbnailCache = SMBThumbnailCache()
    ) {
        self.thumbnailer = thumbnailer
        self.serverStore = serverStore
        self.cache = cache
    }

    /// The artwork for a browsed SMB `Item`, generating + caching a frame-grab on a miss.
    ///
    /// Order matters for cost: the cache key is built from the ItemID's decoded path alone (no
    /// Keychain), so a disk hit or a negative-cache skip returns WITHOUT a Keychain round-trip or
    /// the gate. Only a genuine miss pays for credential assembly + gated generation.
    ///
    /// Returns the local thumbnail (with its duration) once one exists on disk, or `.none` while
    /// one can't be produced. Safe to call from a SwiftUI `.task`: cancellation (scroll-off)
    /// propagates through the gate and into `VLCThumbnailer`, freeing the single permit for a
    /// still-visible tile.
    func artwork(for item: Item, ref: SMBServerRef) async -> MediaArtwork {
        // SMB library items are flat movies; anything else carries server artwork already.
        guard case .movie(let movie) = item else { return .none }
        // The share + share-relative path decode from the ItemID with no Keychain read, so the key
        // (and thus the cache + negative-cache lookups) is available before any I/O. The share is
        // part of the key: one server-id now spans every share on a host, so without it two shares'
        // identical relative paths would share — and overwrite — one cached frame-grab.
        guard let (share, path) = SMBSourceResolver.shareAndPath(for: item) else { return .none }
        let key = SMBThumbnailKey(
            serverID: ref.id.rawValue,
            share: share,
            path: path,
            size: movie.size ?? 0,
            modifiedAt: movie.dateAdded
        )

        if let hit = await cache.existing(for: key) { return MediaArtwork(source: .local(hit.url), duration: hit.duration) }
        if isNegativelyCached(key) { return .none }

        // Real miss → assemble credentials (the only Keychain read) + the smb:// URL.
        let ctx: SMBSourceContext
        do {
            ctx = try await SMBSourceResolver.context(for: item, ref: ref, serverStore: serverStore)
        } catch {
            // Bad ItemID / unbuildable URL / lost password slot — not a decode failure, so
            // don't poison the key.
            return .none
        }

        // Serialise generation (cap=1). A scroll-off while queued throws and never acquires the
        // permit, so there's nothing to release.
        do { try await gate.wait() } catch { return .none }
        let result = await generateUnderGate(key: key, ctx: ctx, ref: ref)
        await gate.signal()
        return result
    }

    /// Runs under a held permit. Holds while a player owns the screen (the permit is kept —
    /// everything queued behind it is paused too), re-checks the disk so a task queued behind a
    /// sibling that already wrote its key skips the demux (coalescing), then generates and stores.
    ///
    /// **Generation rides the local HTTP bridge, not `smb://`.** Pointing libvlc at a
    /// per-fetch `SMBHTTPBridge` (fronting one `SMBRandomAccessReader`) instead of the share
    /// directly buys three things on a high-RTT link (VPN):
    ///  - ONE SMB connection per thumbnail instead of two — the pre-parse and VLCKit's
    ///    internal player each open the URL, and over the bridge both multiplex onto the
    ///    reader's single warm connection instead of paying two WAN SMB handshakes;
    ///  - big reads — the bridge streams the file in 2 MiB slices, where libvlc's smb
    ///    module issues small sequential reads, each charged a round-trip;
    ///  - a kill switch — stopping the bridge on resolve instantly starves the a19
    ///    thumbnailer's zombie player (no cancel API; it otherwise streams the share until
    ///    its internal 45s timer), so an abandoned fetch stops costing bandwidth NOW.
    /// Credentials also stay out of libvlc entirely: they live in the reader's
    /// `URLCredential`; the bridge URL carries only a random one-shot token.
    private func generateUnderGate(key: SMBThumbnailKey, ctx: SMBSourceContext, ref: SMBServerRef) async -> MediaArtwork {
        // Yield the uplink to playback first: the cache re-checks below run AFTER the hold so a
        // sibling's write (or a poisoning) during a long session is seen on resume.
        do { try await awaitPlaybackIdle() } catch { return .none }

        // A sibling task for the same key may have written it while we waited for the permit.
        if let hit = await cache.existing(for: key) { return MediaArtwork(source: .local(hit.url), duration: hit.duration) }
        if isNegativelyCached(key) { return .none }

        let fileName = (ctx.path as NSString).lastPathComponent
        let reader = SMBRandomAccessReader(
            host: ref.data.host, username: ref.data.username, password: ctx.password,
            domain: ref.data.domain, share: ctx.share, path: ctx.path
        )
        // libvlc sniffs the container from the bytes; the advertised type is advisory only.
        let session = SMBBridgeSession(
            reader: reader, fileName: fileName, contentType: "application/octet-stream")
        let bridgeURL: URL
        do {
            // Loopback, not LAN: the thumbnailer is strictly on-device (no AirPlay), and a
            // VPN's policy layer resets self-connections to LAN/link-local addresses — the
            // observed "connection reset by peer" storm that broke generation over VPN.
            // `start` tears the session down itself on failure — a local bind failure is
            // not a decode failure: don't poison, let the next scroll retry.
            bridgeURL = try await session.start(scope: .loopback)
        } catch {
            return .none
        }

        let result = await decodeAndStore(via: bridgeURL, session: session, key: key, fileName: fileName)
        // Torn down on EVERY exit (decodeAndStore never throws): starves a zombie fetch the
        // moment we stop caring (resolve/timeout/cancel) instead of it streaming SMB for up
        // to 45s more. AWAITED, not fire-and-forget: the caller releases the gate permit
        // right after we return, and over VPN a timed-out fetch's drain tail would otherwise
        // overlap the next fetch's fresh SMB session — the exact two-session contention the
        // single permit exists to prevent.
        await session.stop()
        return result
    }

    /// The decode + cache-store + outcome-logging half of a generation, running against an
    /// already-started bridge session. Never throws; the caller owns the session teardown.
    private func decodeAndStore(
        via bridgeURL: URL, session: SMBBridgeSession, key: SMBThumbnailKey, fileName: String
    ) async -> MediaArtwork {
        let generationClock = ContinuousClock()
        let generationStart = generationClock.now
        do {
            // SMB media is REMOTE: the thumbnailer's default 0.3 (30%-in) snapshot forces a deep
            // mid-file seek, and over the share a Matroska cluster read there repeatedly fails
            // ("unable to read KaxCluster during seek, giving up") and sometimes times out — VLC
            // then falls back to an early frame anyway. So ask for an early frame DIRECTLY: 5% in is
            // past a black leader but shallow enough that the bytes are already streamed for the
            // header, so it's fast and reliable, and the frame is no worse than the fallback we were
            // getting. height 320 keeps its default; the ceiling is `generationTimeout` (see its
            // doc). No vlcOptions: the bridge URL needs no credentials.
            let frame = try await thumbnailer.thumbnailData(
                for: bridgeURL, position: 0.05, timeout: Self.generationTimeout)
            let elapsed = generationStart.duration(to: generationClock.now)
            let stats = await session.stats
            Self.log.info("thumbnail generated: \(fileName, privacy: .public) in \(elapsed.formattedSeconds, privacy: .public) (\(stats.formatted, privacy: .public))")
            // A nil from store() is a WRITE failure, not a decode failure — return .none but do
            // NOT poison the key, so the next scroll retries instead of hiding a decodable file.
            guard let cached = await cache.store(frame.data, duration: frame.duration, for: key) else { return .none }
            return MediaArtwork(source: .local(cached.url), duration: cached.duration)
        } catch {
            let elapsed = generationStart.duration(to: generationClock.now)
            // Generation failed/timed out. Poison ONLY if this wasn't a scroll-off cancellation —
            // a cancelled fetch also throws a timeout case, and `Task.isCancelled` is the
            // reliable discriminator regardless of the thrown error type. (A real timeout IS
            // poisoned by design: that's what stops re-charging the full ceiling on every
            // scroll-past.) The error names the lost phase (parseTimedOut vs timedOut) and the
            // stats name the WAN cost — together they distinguish a pathological full-file
            // demux scan (huge bytesRead, parse phase) from plain link starvation.
            if !Task.isCancelled {
                recordFailure(key)
                let stats = await session.stats
                Self.log.info("thumbnail FAILED: \(fileName, privacy: .public) after \(elapsed.formattedSeconds, privacy: .public) (\(String(describing: error), privacy: .public), \(stats.formatted, privacy: .public))")
            } else {
                Self.log.info("thumbnail cancelled: \(fileName, privacy: .public) after \(elapsed.formattedSeconds, privacy: .public)")
            }
            return .none
        }
    }

    // MARK: - Cache management

    /// Total on-disk size of the generated thumbnail cache, for a Settings "Clear Cache" readout.
    func cacheSize() async -> Int64 {
        await cache.totalSize()
    }

    /// Wipes the thumbnail cache and the in-memory failure backoff, so old entries regenerate (now
    /// with durations) and previously-undecodable files get a fresh attempt on next browse.
    func clearCache() async {
        await cache.clear()
        failures.removeAll()
    }

    // MARK: - Playback hold

    /// Playback presentation gate, driven by `RootView` from `PlaybackPresenter.isPlayerPresent`.
    /// Flipping to false releases every held generation; the released tiles then re-contend on
    /// the single-permit `gate` as usual.
    ///
    /// `seq` makes the setter order-independent: RootView spawns a fresh unstructured Task per
    /// presence edge, and Swift guarantees NO FIFO for separate Tasks hopping onto an actor —
    /// a rapid present→dismiss could apply false-then-true and latch `playbackActive` with no
    /// player on screen (freezing generation behind the held gate permit until the next clean
    /// dismissal). Tokens are minted on the MainActor, where the edges ARE ordered, so the
    /// highest-seq edge wins regardless of Task arrival order.
    func setPlaybackActive(_ active: Bool, seq: Int) {
        guard seq > lastPlaybackSeq else { return } // stale/reordered edge — drop it
        lastPlaybackSeq = seq
        guard active != playbackActive else { return }
        playbackActive = active
        guard !active else { return }
        playbackWaiters.resumeAll()
    }

    /// Suspends while playback is active; throws `CancellationError` if the waiting tile's task
    /// is cancelled meanwhile (scroll-off / grid teardown), mirroring `ThumbnailGate.wait()`.
    private func awaitPlaybackIdle() async throws {
        try Task.checkCancellation()
        guard playbackActive else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Re-check: playback may have ended between the fast-path guard above and
                // this closure running (actor turns can interleave across the awaits).
                guard playbackActive else {
                    continuation.resume()
                    return
                }
                playbackWaiters.add(id, continuation)
            }
        } onCancel: {
            Task { await self.cancelPlaybackWaiter(id) }
        }
    }

    private func cancelPlaybackWaiter(_ id: UUID) {
        playbackWaiters.cancel(id)
    }

    // MARK: - Negative cache

    private func isNegativelyCached(_ key: SMBThumbnailKey) -> Bool {
        guard let failedAt = failures[key] else { return false }
        if clock.now - failedAt < Self.failureBackoff { return true }
        failures.removeValue(forKey: key)
        return false
    }

    private func recordFailure(_ key: SMBThumbnailKey) {
        failures[key] = clock.now
    }
}

private extension Duration {
    /// "12.3s" — for the thumbnail outcome logs.
    var formattedSeconds: String {
        String(format: "%.1fs", fractionalSeconds)
    }
}

private extension SMBHTTPBridge.Stats {
    /// "4.2 MiB over 12 connections" — what the fetch cost the share, for the outcome logs.
    /// Fixed-format on purpose (grep-able diagnostics, not UI — locale-aware `.byteCount`
    /// would vary separators/units); the divisor is binary, so the label is MiB.
    var formatted: String {
        String(format: "%.1f MiB over ", Double(bytesRead) / 1_048_576) + "\(connections) connections"
    }
}

/// FIFO list of cancellable continuation waiters, keyed by a mint-once UUID. A value type
/// owned by an actor: every mutation runs under that actor's isolation, so the stored
/// `CheckedContinuation`s never cross an isolation boundary. The suspend/cancel plumbing
/// (UUID mint, `withTaskCancellationHandler`, the onCancel actor-hop) stays in the owning
/// actor — this owns only storage + the remove/resume bookkeeping, shared by `ThumbnailGate`
/// and the provider's playback hold so the cancellation-sensitive removal logic exists once.
private struct WaiterList {
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    mutating func add(_ id: UUID, _ continuation: CheckedContinuation<Void, Error>) {
        waiters.append((id, continuation))
    }

    /// Removes a still-queued waiter and fails it (its task was cancelled before resume).
    mutating func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Hands off to the head waiter. Returns false if none were queued (caller banks a permit).
    mutating func resumeNext() -> Bool {
        guard !waiters.isEmpty else { return false }
        waiters.removeFirst().continuation.resume()
        return true
    }

    /// Releases every waiter. Snapshot-then-clear so no resume observes a stale queue.
    mutating func resumeAll() {
        let all = waiters
        waiters = []
        for waiter in all { waiter.continuation.resume() }
    }
}

/// FIFO async semaphore with a SINGLE permit — hardcoded, not configurable: the 2-permit
/// variant was measured worse over VPN (bandwidth contention; see the `gate` property doc),
/// so widening again should require editing this line past this comment, not passing a number.
/// `wait()` throws `CancellationError` if the calling task is cancelled before it acquires
/// the permit, so a scrolled-off tile gives up its place in line instead of holding visible
/// tiles behind it. A waiter handed the permit just before its own cancellation still
/// acquires it; its in-flight generation then cancels and releases normally, so the permit
/// is always conserved.
private actor ThumbnailGate {
    private var available = 1
    private var waiters = WaiterList()

    func wait() async throws {
        try Task.checkCancellation()
        if available > 0 {
            available -= 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.add(id, continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func signal() {
        // Hand the permit straight to the next waiter (available stays 0), or bank it.
        if !waiters.resumeNext() {
            available += 1
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.cancel(id)
    }
}
