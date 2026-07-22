import Foundation
import OSLog
import ParallaxCore
import ParallaxFileBrowse
import ParallaxJellyfin
import ParallaxPlayback

/// A resolved tile artwork plus the source duration extracted while generating it. The duration
/// rides alongside the image so an SMB tile can show its runtime under the thumbnail; nil when the
/// source carries no artwork, was resolved from a sidecar image (no video length), or libvlc
/// couldn't read a length.
struct MediaArtwork: Sendable, Equatable {
    let source: ArtworkSource
    let duration: Duration?

    static let none = MediaArtwork(source: .none, duration: nil)
}

/// Resolves a poster for a source-neutral `Item` that carries no server artwork — today only the
/// SMB path, which prefers a strict sidecar image beside the file and otherwise generates a
/// frame-grab from the video itself.
///
/// Owns the whole generation pipeline so the call site (a grid tile's `.task`) stays trivial:
///   disk-cache hit (instant) → negative-cache skip (instant) → coalesced generation on a real miss.
///
/// **Coalescing scheduler.** Every key maps to at most one provider-owned generation `Task`
/// (`pending`). A second request for the same key — a re-appearing tile, or a prefetch that a tile
/// then visibly demands — awaits that shared task rather than starting a duplicate. Generation tasks
/// RUN TO COMPLETION once started: they are never cancelled, so a scrolled-past tile's frame-grab is
/// NOT wasted work — the viewport-ahead prefetch window wants every nearby key anyway, and abandoning
/// the decode would just re-charge it on the next scroll. A tile scrolling off only abandons its *await* of the shared
/// task (awaiting a `Never`-failure `Task.value` doesn't propagate the awaiter's cancellation), never
/// the generation.
///
/// **Gate.** A multi-permit, two-priority async gate (`ThumbnailGate`) bounds concurrent SMB work.
/// Visible requests outrank prefetch; `promote` moves a demanded key ahead of the prefetch backlog
/// (gate-owned, so it catches a generation that hasn't queued yet). Concurrency is a constant 3, but
/// admission is link-class-aware: at most ONE wan/unknown-classed generation runs at a time — because
/// 2 permits were MEASURED WORSE over VPN (2026-07-10: fetches are BANDWIDTH-bound, each moves
/// 7–17 MB, and two in flight split the link into lockstep timeouts that each throw away a full
/// download). Enforcing that per permit HOLDER (not via a settable global limit) means a concurrent
/// LAN generation can never widen the gate under a live WAN fetch; low-RTT LAN grabs aren't
/// bandwidth-starved the same way, so they fill the remaining permits.
///
/// **Pooled sessions.** Generation borrows warm SMB connections from a shared `SMBConnectionPool`
/// (injected) instead of standing up a fresh session per fetch. The sidecar reader and the
/// frame-grab bridge both ride the pool; check-in/discard and the libsmb2 teardown guard live in the
/// reader + pool (see `SMBRandomAccessReader.disconnect()`).
///
/// **Failure memory.** A generation failure is recorded both in-memory (fast path) and as a
/// persistent `.fail` marker on disk, so a file libvlc can't decode isn't re-attempted (and
/// re-charged the full timeout) every launch. Backoff is exponential, capped at 24h — never
/// permanent, so a decodable-but-slow-over-VPN file self-heals when circumstances change; Clear
/// Cache or a file change (new size/mtime = new key) resets early.
///
/// **Credentials** never leave this file in the clear: they're read from the Keychain via
/// `SMBSourceResolver` and ride the pooled reader / `vlcOptions`, never logged.
actor MediaArtworkProvider {

    /// Per-fetch outcome diagnostics. File NAMES only (never credentials, never full URLs);
    /// matches the `SMBRandomAccessReader` path-logging precedent.
    private static let log = Logger(subsystem: "com.lhdev.parallax", category: "thumbnails")

    private let cache: SMBThumbnailCache
    /// `@MainActor`-isolated; constructed on the main actor in `AppDependencies` and called via
    /// `await` (it hops to main for the actual decode).
    private let thumbnailer: VLCThumbnailer
    private let serverStore: ServerStore
    /// Shared warm-connection pool. Its cold-connect latency also classes the link (LAN/WAN), which
    /// shapes each generation's gate admission (WAN serialised to 1, LAN up to 3).
    private let pool: SMBSharePool

    /// Multi-permit, two-priority gate — see the type doc. Admission is link-class-aware (3 wide,
    /// WAN serialised to 1). The 2-permit-worse-over-VPN measurement (2026-07-10) is why WAN pins to 1.
    private let gate = ThumbnailGate()

    /// At most one in-flight generation `Task` per key. A duplicate request awaits the existing task's
    /// value; the task removes its own entry on completion. Awaiting the task never cancels it.
    private var pending: [SMBThumbnailKey: Task<MediaArtwork, Never>] = [:]

    /// Hard ceiling per FRAME-GRAB generation (pre-parse + fetch share it). 30s, not the thumbnailer's
    /// 20s default: over VPN a *successful* fetch measured 11.1s and several legitimate files timed
    /// out at 20s, so the default ceiling sat inside the observed success band. On LAN a fetch takes
    /// 1–3s, so only genuinely broken files ever pay this — and they're then backed off anyway.
    private static let generationTimeout: Duration = .seconds(30)

    /// Sidecar reads are bounded tighter: a poster is small, and a sidecar that can't stream in ~10s
    /// is a wedge worth abandoning to the frame-grab (which has its own, longer ceiling).
    private static let sidecarReadTimeout: TimeInterval = 10
    /// A sidecar image larger than this isn't a tile poster — skip it and frame-grab instead. 8 MiB
    /// comfortably covers a 4K-ish JPEG/PNG scraper poster without reading a misplaced huge file.
    private static let maxSidecarBytes: Int64 = 8 * 1024 * 1024
    /// Downscale sidecars to this long-edge before HEIC-encoding — a browse tile never needs more,
    /// and it caps the decode+store cost of an oversized poster.
    private static let sidecarMaxPixel = 1280

    /// In-memory MIRROR of the persistent failure state (attempts + when last recorded), the fast
    /// path consulted before the on-disk `.fail` marker. Counts are adopted FROM the cache
    /// (`recordFailure`'s return value), never seeded independently — the disk marker is the source
    /// of truth, so a relaunch can't restart a permanently-poisoned key at attempt 1 and sneak past
    /// its backoff. Transient failures self-heal by backoff EXPIRY (exponential, capped), not by
    /// relaunch; expired entries are pruned on lookup so the map stays bounded over a long session.
    private var failures: [SMBThumbnailKey: (attempts: Int, instant: ContinuousClock.Instant)] = [:]
    private let clock = ContinuousClock()
    private static let failureBackoff: Duration = .seconds(180)
    /// Backoff ceiling — deliberately NOT permanent: a decodable-but-slow file (a big MKV that
    /// times out over VPN but grabs in 1–3s on LAN) must get another chance when circumstances
    /// change. 24h means a chronically-failing key costs at most one 30s attempt per day, while a
    /// genuinely broken file stays effectively silenced.
    private static let maxBackoff: Duration = .seconds(24 * 3600)

    /// True while a player session owns the screen (driven by `RootView` from
    /// `PlaybackPresenter.isPlayerPresent`). Generation HOLDS while set: the full-screen player
    /// covers the grid without cancelling its cells' `.task`s, so without this the pipeline keeps
    /// streaming SMB bytes over the same uplink the player is using (worst over VPN). Cache hits and
    /// negative-cache skips still return instantly — only demux waits (the permit is kept, so
    /// everything queued behind it is paused too).
    private var playbackActive = false
    private var playbackWaiters = WaiterList()
    /// Highest presence-edge token applied so far — see `setPlaybackActive(_:seq:)`.
    private var lastPlaybackSeq = 0

    /// - Parameter pool: the shared SMB connection pool. Defaults to a fresh pool so previews/tests
    ///   need not name one (which would force the `SMB2Manager` specialization into their module, and
    ///   the app-test bundle doesn't link AMSMB2); production injects the ONE app-scoped pool from
    ///   `AppDependencies` so browse + playback reuse the same warm connections.
    init(
        thumbnailer: VLCThumbnailer,
        serverStore: ServerStore,
        pool: SMBSharePool = SMBSharePool(),
        cache: SMBThumbnailCache = SMBThumbnailCache()
    ) {
        self.thumbnailer = thumbnailer
        self.serverStore = serverStore
        self.pool = pool
        self.cache = cache
    }

    /// The artwork for a browsed SMB `Item`, coalescing onto (or starting) a shared generation on a
    /// miss. `sidecar` is the strict sibling-image match from the browse listing (nil = none), tried
    /// before any frame-grab.
    ///
    /// Order matters for cost: the cache key is built from the ItemID's decoded path alone (no
    /// Keychain), so a disk hit or a negative-cache skip returns WITHOUT a Keychain round-trip or the
    /// gate. Only a genuine miss coalesces onto gated generation. A visible request `bump`s a pending
    /// prefetch for the same key ahead of the prefetch queue. Cancelling the caller's task (scroll-off)
    /// abandons only this await — the shared generation runs to completion for the next requester.
    func artwork(for item: Item, ref: SMBServerRef, sidecar: SMBDirectoryEntry?) async -> MediaArtwork {
        guard let key = thumbnailKey(for: item, ref: ref) else { return .none }

        if let hit = await cache.existing(for: key) { return MediaArtwork(source: .local(hit.url), duration: hit.duration) }
        if await isNegativelyCached(key) { return .none }

        if let existing = pending[key] {
            // A visible tile wants a key another request already scheduled — promote it ahead of the
            // prefetch backlog. Gate-OWNED promotion: the key is recorded in the gate and consulted
            // atomically at enqueue, so this also catches a generation task that hasn't reached
            // `wait` yet (still suspended in `linkClass`), which a queued-waiter-only bump would miss.
            await gate.promote(key)
            if pending[key] == nil {
                // The generation completed while `promote` hopped actors, and actor hops from
                // separate tasks are UNORDERED — its `forget` may have run BEFORE our `promote`,
                // stranding the key in the gate's promotion set. Re-forget; idempotent either way.
                await gate.forget(key)
            }
            return await existing.value
        }
        return await scheduleGeneration(key: key, item: item, ref: ref, sidecar: sidecar, priority: .visible).value
    }

    /// Warms a viewport-ahead SLICE of a browsed folder — the view hands over ~a dozen rows past the
    /// tile that just appeared, NOT the whole listing (explicit user policy, perception over
    /// completeness: scroll landings stay warm while a huge directory never fetches wall-to-wall).
    /// Schedules generation for the items not already cached / negatively-cached / pending, at
    /// PREFETCH priority (yielding to visible tiles), and does NOT await them. Runs on every link
    /// class; the coalescing (a visible `artwork(for:)` for the same key just awaits the
    /// already-running task) means a prefetch is never duplicated work, only earlier work.
    ///
    /// Already-scheduled generations still run to completion after the folder is left — the window
    /// bounds how much gets SCHEDULED, not what finishes. The only pauses are the playback hold and
    /// app termination.
    func prefetch(_ items: [Item], ref: SMBServerRef, sidecars: [ItemID: SMBDirectoryEntry]) async {
        // Classify the host BEFORE scheduling: every generation bakes its link class at schedule
        // time, so without this an entire first-of-session batch reads nil — conservatively
        // WAN-serialised — and a LAN wall never sees its 3-permit concurrency until the batch
        // after. One probe checkout measures the class AND leaves a warm connection the first
        // fetch then reuses. Best-effort: a probe failure just leaves the batch conservative.
        await classifyHostIfNeeded(items: items, ref: ref)
        for item in items {
            guard let key = thumbnailKey(for: item, ref: ref) else { continue }
            if pending[key] != nil { continue }
            if await cache.existing(for: key) != nil { continue }
            if await isNegativelyCached(key) { continue }
            _ = scheduleGeneration(key: key, item: item, ref: ref, sidecar: sidecars[item.id], priority: .prefetch)
        }
    }

    /// The cache key for a browsed SMB item, or nil for a non-movie (anything else carries server
    /// artwork already) or an undecodable ItemID — the ONE home of the movie→key recipe shared by
    /// `artwork` and `prefetch`. The share + share-relative path decode from the ItemID with no
    /// Keychain read, so the key (and thus the cache + negative-cache lookups) is available before
    /// any I/O. The share is part of the key: one server-id spans every share on a host, so without
    /// it two shares' identical relative paths would share — and overwrite — one cached thumbnail.
    private func thumbnailKey(for item: Item, ref: SMBServerRef) -> SMBThumbnailKey? {
        guard case .movie(let movie) = item else { return nil }
        guard let (share, path) = SMBSourceResolver.shareAndPath(for: item) else { return nil }
        return SMBThumbnailKey(
            serverID: ref.id.rawValue, share: share, path: path,
            size: movie.size ?? 0, modifiedAt: movie.dateAdded
        )
    }

    /// One-time link classification for `ref`'s host, run before a prefetch batch schedules. Skips
    /// instantly once the pool knows the class; otherwise pays one Keychain read + one probe
    /// checkout (which the pool keeps warm for the first real fetch). Non-movie items can't build a
    /// context, so the probe rides the first movie in the batch.
    private func classifyHostIfNeeded(items: [Item], ref: SMBServerRef) async {
        guard await pool.linkClass(host: ref.data.host) == nil else { return }
        guard let first = items.first(where: { if case .movie = $0 { return true } else { return false } }),
              let ctx = try? await SMBSourceResolver.context(for: first, ref: ref, serverStore: serverStore)
        else { return }
        _ = await pool.ensureLinkClass(SMBConnectionTarget(
            host: ref.data.host, username: ref.data.username, password: ctx.password,
            domain: ref.data.domain, share: ctx.share
        ))
    }

    /// Creates (or returns the existing) shared generation task for `key`, stored in `pending`. The
    /// task runs to completion and clears its own `pending` entry.
    private func scheduleGeneration(
        key: SMBThumbnailKey, item: Item, ref: SMBServerRef, sidecar: SMBDirectoryEntry?, priority: GatePriority
    ) -> Task<MediaArtwork, Never> {
        if let existing = pending[key] { return existing }
        let task = Task { [self] in
            let result = await generate(key: key, item: item, ref: ref, sidecar: sidecar, priority: priority)
            pending[key] = nil
            await gate.forget(key)  // drop any recorded promotion with the completed generation
            return result
        }
        pending[key] = task
        return task
    }

    // MARK: - Generation

    /// One full generation: read the link class, acquire a gate permit at `priority` (or bail if the
    /// bounded prefetch backlog evicted this waiter), run the held-permit pipeline (sidecar →
    /// frame-grab), then release. Never throws.
    private func generate(
        key: SMBThumbnailKey, item: Item, ref: SMBServerRef, sidecar: SMBDirectoryEntry?, priority: GatePriority
    ) async -> MediaArtwork {
        // Link class shapes ADMISSION, not a global limit: the gate always allows 3 concurrent
        // generations but at most ONE wan/unknown-classed one (the measured-worse-over-VPN result),
        // enforced per permit holder so a LAN generation can never widen the gate under a live WAN
        // fetch.
        let link = await pool.linkClass(host: ref.data.host)

        guard await gate.wait(key: key, priority: priority, link: link) else {
            // Evicted from the bounded prefetch backlog (superseded by newer windows before any
            // permit): no SMB work happened, so record NOTHING — a visible request or a re-entered
            // window simply reschedules it (the pending entry clears in scheduleGeneration's tail).
            return .none
        }
        let result = await generateHoldingPermit(key: key, item: item, ref: ref, sidecar: sidecar, link: link)
        await gate.signal(link: link)
        return result
    }

    /// Runs under a held permit. Holds while a player owns the screen (the permit is kept), re-checks
    /// the disk + negative cache AFTER the hold (coalescing: a sibling's write or poisoning during a
    /// long session is seen on resume), assembles credentials once, then tries the sidecar tier and
    /// falls through to the frame-grab. Never throws.
    private func generateHoldingPermit(
        key: SMBThumbnailKey, item: Item, ref: SMBServerRef, sidecar: SMBDirectoryEntry?,
        link: SMBLinkClass?
    ) async -> MediaArtwork {
        // Yield the uplink to playback first; the re-checks below run AFTER the hold.
        await awaitPlaybackIdle()

        if let hit = await cache.existing(for: key) { return MediaArtwork(source: .local(hit.url), duration: hit.duration) }
        if await isNegativelyCached(key) { return .none }

        // Assemble credentials (the only Keychain read). A bad ItemID / unbuildable URL / lost
        // password slot is NOT a decode failure, so don't poison the key.
        let ctx: SMBSourceContext
        do {
            ctx = try await SMBSourceResolver.context(for: item, ref: ref, serverStore: serverStore)
        } catch {
            return .none
        }
        let fileName = (ctx.path as NSString).lastPathComponent

        // Sidecar tier first: a strict sibling image is a truer poster than a mid-file frame, and
        // reading + downscaling a small image is far cheaper than a demux. ANY sidecar failure falls
        // through to the frame-grab WITHOUT poisoning the key.
        if let sidecar,
           let art = await trySidecar(sidecar: sidecar, ctx: ctx, ref: ref, key: key,
                                      fileName: fileName, link: link) {
            return art
        }

        return await frameGrab(ctx: ctx, ref: ref, key: key, fileName: fileName, link: link)
    }

    /// The sidecar tier: read the whole sibling image over a pooled reader (bounded by
    /// `withHardTimeout`), downscale to tile resolution, HEIC-encode, and store with no duration.
    /// Returns the resolved artwork on success, or nil to fall through to the frame-grab. A nil is
    /// NEVER a poison — a missing/broken sidecar just means "use a frame-grab", not "this file is bad".
    private func trySidecar(
        sidecar: SMBDirectoryEntry, ctx: SMBSourceContext, ref: SMBServerRef, key: SMBThumbnailKey,
        fileName: String, link: SMBLinkClass?
    ) async -> MediaArtwork? {
        let size = sidecar.size
        guard size > 0, size <= Self.maxSidecarBytes else { return nil }

        // The sidecar lives in the video's directory — build its share-relative path the same way the
        // browse view builds child paths (parent/name, or bare name at the directory root).
        let directory = (ctx.path as NSString).deletingLastPathComponent
        let sidecarPath = directory.isEmpty ? sidecar.name : "\(directory)/\(sidecar.name)"
        let reader = SMBRandomAccessReader(
            pool: pool, host: ref.data.host, username: ref.data.username, password: ctx.password,
            domain: ref.data.domain, share: ctx.share, path: sidecarPath
        )
        let start = clock.now
        do {
            let capped = Int(size)
            let data = try await withHardTimeout(seconds: Self.sidecarReadTimeout) {
                try await reader.read(offset: 0, length: capped)
            }
            guard let image = ImageTranscode.downscaledImage(from: data, maxPixelSize: Self.sidecarMaxPixel) else {
                throw SidecarFailure.undecodable
            }
            let heic = try ImageTranscode.encodeHEIC(image)
            // Clean lifecycle → the pooled connection checks back in reusable.
            await reader.disconnect()
            let elapsed = start.duration(to: clock.now)
            guard let cached = await cache.store(heic, duration: nil, for: key) else {
                // A write failure — not a decode failure. Fall through without poisoning.
                Self.log.info("thumbnail sidecar store failed: \(fileName, privacy: .public) [\(Self.context(link), privacy: .public)] — frame-grab fallback")
                return nil
            }
            failures[key] = nil  // disk marker already cleared by store()
            Self.log.info("thumbnail generated: \(fileName, privacy: .public) [tier=sidecar \(Self.context(link), privacy: .public)] in \(elapsed.formattedSeconds, privacy: .public) (\(size.mibLabel, privacy: .public) read)")
            return MediaArtwork(source: .local(cached.url), duration: nil)
        } catch {
            // A thrown read taints the borrow → discarded on disconnect (never returned to idle).
            await reader.disconnect()
            let elapsed = start.duration(to: clock.now)
            Self.log.info("thumbnail sidecar FELL THROUGH: \(fileName, privacy: .public) [tier=sidecar \(Self.context(link), privacy: .public)] after \(elapsed.formattedSeconds, privacy: .public) (\(String(describing: error), privacy: .public)) — frame-grab fallback")
            return nil
        }
    }

    /// The frame-grab tier — rides the local HTTP bridge over a pooled reader, exactly as before.
    ///
    /// **Generation rides the local HTTP bridge, not `smb://`.** Pointing libvlc at a per-fetch
    /// `SMBHTTPBridge` (fronting one pooled `SMBRandomAccessReader`) instead of the share directly
    /// buys three things on a high-RTT link (VPN):
    ///  - ONE SMB connection per thumbnail instead of two — the pre-parse and VLCKit's internal
    ///    player each open the URL, and over the bridge both multiplex onto the reader's single warm
    ///    connection instead of paying two WAN SMB handshakes;
    ///  - big reads — the bridge streams the file in 2 MiB slices, where libvlc's smb module issues
    ///    small sequential reads, each charged a round-trip;
    ///  - a kill switch — stopping the bridge on resolve instantly starves the a19 thumbnailer's
    ///    zombie player (no cancel API; it otherwise streams the share until its internal 45s timer).
    /// Credentials also stay out of libvlc entirely: they live in the reader's pooled target; the
    /// bridge URL carries only a random one-shot token.
    private func frameGrab(
        ctx: SMBSourceContext, ref: SMBServerRef, key: SMBThumbnailKey,
        fileName: String, link: SMBLinkClass?
    ) async -> MediaArtwork {
        let reader = SMBRandomAccessReader(
            pool: pool, host: ref.data.host, username: ref.data.username, password: ctx.password,
            domain: ref.data.domain, share: ctx.share, path: ctx.path
        )
        // libvlc sniffs the container from the bytes; the advertised type is advisory only.
        let session = SMBBridgeSession(
            reader: reader, fileName: fileName, contentType: "application/octet-stream")
        let bridgeURL: URL
        do {
            // Loopback, not LAN: the thumbnailer is strictly on-device (no AirPlay), and a VPN's
            // policy layer resets self-connections to LAN/link-local addresses — the observed
            // "connection reset by peer" storm that broke generation over VPN. `start` tears the
            // session down itself on failure — a local bind failure is not a decode failure: don't
            // poison, let the next scroll retry.
            bridgeURL = try await session.start(scope: .loopback)
        } catch {
            return .none
        }

        let result = await decodeAndStore(via: bridgeURL, session: session, key: key, fileName: fileName, link: link)
        // Torn down on EVERY exit (decodeAndStore never throws): starves a zombie fetch the moment we
        // stop caring instead of it streaming SMB for up to 45s more. AWAITED, not fire-and-forget:
        // the caller releases the gate permit right after we return, and the bridge-first teardown
        // checks the pooled reader back in (or discards a tainted borrow).
        await session.stop()
        return result
    }

    /// The decode + cache-store + outcome-logging half of a frame-grab, running against an
    /// already-started bridge session. Never throws; the caller owns the session teardown. A failure
    /// poisons the key (records the failure) — the shared task is never cancelled, so a thrown error
    /// here is always a real decode/link failure, never a scroll-off.
    private func decodeAndStore(
        via bridgeURL: URL, session: SMBBridgeSession, key: SMBThumbnailKey, fileName: String,
        link: SMBLinkClass?
    ) async -> MediaArtwork {
        let start = clock.now
        do {
            // SMB media is REMOTE: the thumbnailer's default 0.3 (30%-in) snapshot forces a deep
            // mid-file seek, and over the share a Matroska cluster read there repeatedly fails and
            // sometimes times out. So ask for an early frame DIRECTLY: 5% in is past a black leader but
            // shallow enough that the bytes are already streamed for the header. height 320 keeps its
            // default; the ceiling is `generationTimeout`. No vlcOptions: the bridge URL needs none.
            let frame = try await thumbnailer.thumbnailData(
                for: bridgeURL, position: 0.05, timeout: Self.generationTimeout)
            let elapsed = start.duration(to: clock.now)
            let stats = await session.stats
            failures[key] = nil  // a decodable file: clear the in-memory stamp (store clears the disk marker)
            Self.log.info("thumbnail generated: \(fileName, privacy: .public) [tier=framegrab \(Self.context(link), privacy: .public)] in \(elapsed.formattedSeconds, privacy: .public) (\(stats.formatted, privacy: .public))")
            // A nil from store() is a WRITE failure, not a decode failure — return .none but do NOT
            // poison the key, so the next scroll retries instead of hiding a decodable file.
            guard let cached = await cache.store(frame.data, duration: frame.duration, for: key) else { return .none }
            return MediaArtwork(source: .local(cached.url), duration: cached.duration)
        } catch {
            let elapsed = start.duration(to: clock.now)
            // Generation failed/timed out — a real failure (the shared task is never cancelled). Poison
            // so the full ceiling isn't re-charged on every scroll-past. The error names the lost phase
            // (parseTimedOut vs timedOut) and the stats name the WAN cost — together distinguishing a
            // pathological full-file demux scan from plain link starvation.
            await recordFailure(key)
            let stats = await session.stats
            Self.log.info("thumbnail FAILED: \(fileName, privacy: .public) [tier=framegrab \(Self.context(link), privacy: .public)] after \(elapsed.formattedSeconds, privacy: .public) (\(String(describing: error), privacy: .public), \(stats.formatted, privacy: .public))")
            return .none
        }
    }

    // MARK: - Cache management

    /// Total on-disk size of the generated thumbnail cache, for a Settings "Clear Cache" readout.
    func cacheSize() async -> Int64 {
        await cache.totalSize()
    }

    /// Wipes the thumbnail cache and the in-memory failure backoff, so old entries regenerate and
    /// previously-undecodable files get a fresh attempt on next browse.
    func clearCache() async {
        await cache.clear()
        failures.removeAll()
    }

    // MARK: - Playback hold

    /// Playback presentation gate, driven by `RootView` from `PlaybackPresenter.isPlayerPresent`.
    /// Flipping to false releases every held generation; the released tiles then re-contend on the
    /// gate as usual.
    ///
    /// `seq` makes the setter order-independent: RootView spawns a fresh unstructured Task per presence
    /// edge, and Swift guarantees NO FIFO for separate Tasks hopping onto an actor — a rapid
    /// present→dismiss could apply false-then-true and latch `playbackActive` with no player on screen.
    /// Tokens are minted on the MainActor, where the edges ARE ordered, so the highest-seq edge wins
    /// regardless of Task arrival order.
    func setPlaybackActive(_ active: Bool, seq: Int) {
        guard seq > lastPlaybackSeq else { return } // stale/reordered edge — drop it
        lastPlaybackSeq = seq
        guard active != playbackActive else { return }
        playbackActive = active
        guard !active else { return }
        playbackWaiters.resumeAll()
    }

    /// Suspends while playback is active. Not cancellable: only a generation task (which runs to
    /// completion, never cancelled) ever awaits this, so the resume only ever comes from
    /// `setPlaybackActive(false)`.
    private func awaitPlaybackIdle() async {
        guard playbackActive else { return }
        // The Bool is the WaiterList's abandon channel; the playback hold never abandons, so the
        // value is always true and deliberately ignored.
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            // Re-check: playback may have ended between the guard above and this closure running
            // (actor turns can interleave across the awaits).
            guard playbackActive else {
                continuation.resume(returning: true)
                return
            }
            playbackWaiters.add(key: nil, link: nil, continuation)
        }
    }

    // MARK: - Negative cache

    /// Whether `key` is still within its failure backoff. Consults the in-memory stamp first (fast
    /// path), then the persistent `.fail` marker on the miss path (survives a relaunch). Backoff is
    /// `180s × 2^(attempts−1)` capped at 24h — never permanent (see `maxBackoff`); Clear Cache or a
    /// file change (new key) resets early.
    private func isNegativelyCached(_ key: SMBThumbnailKey) async -> Bool {
        if let mem = failures[key] {
            if isBackedOff(attempts: mem.attempts, elapsed: mem.instant.duration(to: clock.now)) { return true }
            // Expired — prune the mirror entry so the map stays bounded over a long session. The
            // disk marker carries the SAME count with an older-or-equal stamp, so it reads expired
            // too; no need to consult it on this pass.
            failures.removeValue(forKey: key)
            return false
        }
        if let disk = await cache.failureState(for: key) {
            let elapsedSeconds = max(0, Date().timeIntervalSince(disk.lastAttempt))
            return isBackedOff(attempts: disk.attempts, elapsed: .seconds(elapsedSeconds))
        }
        return false
    }

    private func isBackedOff(attempts: Int, elapsed: Duration) -> Bool {
        guard attempts > 0 else { return false }
        // Exponent clamped BEFORE shifting: a marker that has failed for months carries a large
        // attempt count, and an unclamped `1 << (attempts - 1)` would overflow. 2^9 × 180s already
        // exceeds the 24h ceiling, so the clamp changes nothing observable.
        let backoff = min(Self.failureBackoff * (1 << min(attempts - 1, 9)), Self.maxBackoff)
        return elapsed < backoff
    }

    private func recordFailure(_ key: SMBThumbnailKey) async {
        // The disk marker owns the attempt count (it survives relaunch); mirror exactly what it
        // recorded so memory and disk can never disagree on how poisoned a key is.
        let recorded = await cache.recordFailure(for: key)
        failures[key] = (attempts: recorded.attempts, instant: clock.now)
    }

    // MARK: - Diagnostics helpers

    /// `link=wan permits=1` — the shared diagnostic context fragment for the outcome logs. The
    /// permits label is DERIVED here (the class's effective concurrency under the gate's wan cap)
    /// rather than threaded through the pipeline as a parameter nothing else uses.
    private static func context(_ link: SMBLinkClass?) -> String {
        "link=\(linkLabel(link)) permits=\((link == .lan) ? 3 : 1)"
    }

    private static func linkLabel(_ link: SMBLinkClass?) -> String {
        switch link {
        case .lan: "lan"
        case .wan: "wan"
        case nil: "unknown"
        }
    }

}

/// A sidecar tier failure that isn't a thrown SMB error (e.g. the bytes weren't a decodable image).
/// Routed through the same catch as a read throw so both fall through to the frame-grab.
private enum SidecarFailure: Error {
    case undecodable
}

private extension Duration {
    /// "12.3s" — for the thumbnail outcome logs.
    var formattedSeconds: String {
        String(format: "%.1fs", fractionalSeconds)
    }
}

private extension Int64 {
    /// "4.2 MiB" — fixed-format binary-MiB label shared by every outcome-log byte count
    /// (grep-able diagnostics, not UI — locale-aware `.byteCount` would vary separators/units).
    var mibLabel: String {
        String(format: "%.1f MiB", Double(self) / 1_048_576)
    }
}

private extension SMBHTTPBridge.Stats {
    /// "4.2 MiB over 12 connections" — what a frame-grab cost the share, for the outcome logs.
    var formatted: String {
        "\(Int64(bytesRead).mibLabel) over \(connections) connections"
    }
}

// MARK: - Gate

private enum GatePriority: Sendable {
    /// A tile currently on screen wants this key — served before any prefetch.
    case visible
    /// Warming a folder ahead of scroll — yields to every visible request.
    case prefetch
}

/// FIFO list of continuation waiters, keyed by an optional generation key and the waiter's link
/// class (both nil for the playback hold, which is key- and class-agnostic). A value type owned by
/// an actor: every mutation runs under that actor's isolation, so the stored `CheckedContinuation`s
/// never cross an isolation boundary. Continuations resume with a Bool — true = proceed (permit
/// granted / hold released), false = ABANDONED (evicted from the bounded prefetch backlog; the
/// generation bails without SMB work). Shared by `ThumbnailGate` and the playback hold so the FIFO
/// bookkeeping exists once.
private struct WaiterList {
    typealias Waiter = (key: SMBThumbnailKey?, link: SMBLinkClass?, continuation: CheckedContinuation<Bool, Never>)

    private var waiters: [Waiter] = []

    var count: Int { waiters.count }

    mutating func add(key: SMBThumbnailKey?, link: SMBLinkClass?, _ continuation: CheckedContinuation<Bool, Never>) {
        waiters.append((key, link, continuation))
    }

    /// Removes and returns the first waiter whose link class passes `admissible`, or nil. FIFO within
    /// the admissible subset — a WAN waiter blocked by the wan cap is skipped, not head-of-line
    /// blocking the LAN waiters behind it.
    mutating func removeFirst(where admissible: (SMBLinkClass?) -> Bool) -> Waiter? {
        guard let index = waiters.firstIndex(where: { admissible($0.link) }) else { return nil }
        return waiters.remove(at: index)
    }

    /// Removes and returns the OLDEST waiter unconditionally (the prefetch-backlog eviction), or nil.
    mutating func removeOldest() -> Waiter? {
        waiters.isEmpty ? nil : waiters.removeFirst()
    }

    /// Removes the first waiter matching `key` (for gate promotion), or nil.
    mutating func removeWaiter(key: SMBThumbnailKey) -> Waiter? {
        guard let index = waiters.firstIndex(where: { $0.key == key }) else { return nil }
        return waiters.remove(at: index)
    }

    /// Releases every waiter to proceed. Snapshot-then-clear so no resume observes a stale queue.
    mutating func resumeAll() {
        let all = waiters
        waiters = []
        for waiter in all { waiter.continuation.resume(returning: true) }
    }
}

/// Multi-permit, two-priority async gate bounding concurrent SMB thumbnail work, with link-class-
/// aware admission.
///
/// Concurrency is a CONSTANT `maxConcurrent` (3), but at most ONE wan/unknown-classed generation
/// holds a permit at a time — the 2-permit-worse-over-VPN measurement (2026-07-10: bandwidth
/// contention, lockstep timeouts each wasting a full 10+ MB download) enforced structurally per
/// permit HOLDER. A settable global limit was rejected: with two hosts of different classes, a later
/// LAN generation's "widen to 3" would land under a live WAN fetch and reintroduce exactly the
/// measured pathology (last-writer-wins). Per-holder accounting can't: the WAN cap travels with the
/// permit. A WAN transfer plus fast LAN grabs coexist because they don't share a bottleneck link.
///
/// Two FIFO waiter lists: visible requests are admitted before prefetch. Promotion is gate-OWNED:
/// `promote(key)` records the key in a set consulted atomically at enqueue AND moves any
/// already-queued prefetch waiter to the visible band — so a visible demand can never miss a
/// generation task that hasn't reached `wait` yet (the pre-enqueue window a queued-waiter-only bump
/// would lose). `forget(key)` drops the record when the key's generation completes.
private actor ThumbnailGate {
    private static let maxConcurrent = 3
    /// Ceiling on QUEUED prefetch waiters. Prefetch windows accumulate across folders (generations
    /// are never cancelled), so without a bound a drill-through-many-folders session queues stale
    /// work that saturates a WAN link for minutes after the user left. Beyond the cap, the OLDEST
    /// queued prefetch waiter is resumed as ABANDONED (false) — it did no SMB work, records no
    /// failure, and a visible request or a re-entered window simply reschedules it. Roughly one
    /// window's worth: newer windows describe where the user actually is.
    private static let maxQueuedPrefetch = 24

    private var inFlight = 0
    /// WAN/unknown-classed permits currently held — `admissible` caps this at 1.
    private var wanInFlight = 0
    private var visible = WaiterList()
    private var prefetch = WaiterList()
    /// Keys a tile visibly demanded, consulted at enqueue so a late-arriving waiter lands in the
    /// visible band even when `promote` ran before its generation task reached `wait`.
    private var promotedKeys: Set<SMBThumbnailKey> = []

    /// Acquires a permit, suspending (FIFO within the priority band) until admissible. Returns true
    /// with the permit held, or false when the waiter was evicted from the bounded prefetch backlog
    /// — the caller must bail without SMB work and WITHOUT `signal`ing (no permit was granted).
    func wait(key: SMBThumbnailKey, priority: GatePriority, link: SMBLinkClass?) async -> Bool {
        if admissible(link) {
            account(link)
            return true
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let effective: GatePriority = promotedKeys.contains(key) ? .visible : priority
            switch effective {
            case .visible:
                visible.add(key: key, link: link, continuation)
            case .prefetch:
                prefetch.add(key: key, link: link, continuation)
                if prefetch.count > Self.maxQueuedPrefetch, let evicted = prefetch.removeOldest() {
                    evicted.continuation.resume(returning: false)
                }
            }
        }
        // Resumed by `admit` (true; permit already accounted) or backlog eviction (false).
    }

    /// Releases a held permit (declassing it) and admits the next admissible waiter (visible first).
    func signal(link: SMBLinkClass?) {
        inFlight -= 1
        if link != .lan { wanInFlight -= 1 }
        admit()
    }

    /// Records a visible demand for `key` and moves an already-queued prefetch waiter for it to the
    /// visible band. Safe to call before the key's generation reaches `wait` — the recorded key is
    /// consulted at enqueue, closing that race. (No `admit` here: moving bands frees no permit.)
    func promote(_ key: SMBThumbnailKey) {
        promotedKeys.insert(key)
        guard let waiter = prefetch.removeWaiter(key: key) else { return }
        visible.add(key: key, link: waiter.link, waiter.continuation)
    }

    /// Drops a completed key's promotion record (its generation finished; nothing left to promote).
    func forget(_ key: SMBThumbnailKey) {
        promotedKeys.remove(key)
    }

    /// A `link`-classed generation may take a permit: a free slot, and — for wan/unknown — no other
    /// wan/unknown permit in flight.
    private func admissible(_ link: SMBLinkClass?) -> Bool {
        guard inFlight < Self.maxConcurrent else { return false }
        return link == .lan || wanInFlight == 0
    }

    private func account(_ link: SMBLinkClass?) {
        inFlight += 1
        if link != .lan { wanInFlight += 1 }
    }

    /// Hands out permits to waiting generations while any is admissible: visible band first, then
    /// prefetch, skipping over waiters the wan cap blocks (a blocked WAN waiter admits as soon as the
    /// running WAN permit frees; LAN waiters behind it need not wait for that). Each admitted
    /// waiter's permit is accounted here (its `wait` won't re-account).
    private func admit() {
        while true {
            guard let waiter = visible.removeFirst(where: { admissible($0) })
                ?? prefetch.removeFirst(where: { admissible($0) }) else { break }
            account(waiter.link)
            waiter.continuation.resume(returning: true)
        }
    }
}
