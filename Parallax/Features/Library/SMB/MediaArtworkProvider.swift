import Foundation
import os
import OSLog
import ParallaxCore
import ParallaxFileBrowse
import ParallaxJellyfin
import ParallaxPlayback

/// A resolved tile artwork plus the source duration extracted while generating it. The duration
/// rides alongside the image so an SMB tile can show its runtime under the thumbnail; nil when the
/// source carries no artwork, or when no length was ever resolved for it — a sidecar image has no
/// video length of its own, and libvlc can't always read one.
/// `nonisolated` for the same app-target MainActor-default reason as `SMBThumbnailKey`: this value
/// is produced and compared inside the `MediaArtworkProvider` actor, and an inferred main-actor
/// isolation makes even `MediaArtwork.none` unreachable from there (an error under the Swift 6
/// language mode).
nonisolated struct MediaArtwork: Sendable, Equatable {
    let source: ArtworkSource
    let duration: Duration?

    static let none = MediaArtwork(source: .none, duration: nil)
}

/// Resolves a poster for a source-neutral `Item` that carries no server artwork — today only the
/// SMB path, which prefers a strict sidecar image beside the file, then (for MKV) an embedded
/// Matroska cover-art attachment, and otherwise generates a frame-grab from the video itself.
///
/// Owns the whole generation pipeline so the call site (a grid tile's `.task`) stays trivial:
///   disk-cache hit (instant) → negative-cache skip (instant) → coalesced generation on a real miss.
///
/// **Coalescing scheduler.** Every key maps to at most one provider-owned generation `Task`
/// (`pending`). A second request for the same key — a re-appearing tile, or a prefetch that a tile
/// then visibly demands — awaits that shared task rather than starting a duplicate. Generation tasks
/// RUN TO COMPLETION once started: they are never cancelled, so a scrolled-past tile's frame-grab is
/// NOT wasted work — the viewport-ahead prefetch window wants every nearby key anyway, and abandoning
/// the decode would just re-charge it on the next scroll. A tile scrolling off abandons its *await* of the shared
/// task (awaiting a `Never`-failure `Task.value` doesn't propagate the awaiter's cancellation) and
/// withdraws the key's VISIBLE claim (`gate.demote`) — never the generation itself.
///
/// **Gate.** A multi-permit, two-band async gate (`ThumbnailGate`) bounds concurrent SMB work
/// with a per-host AIMD admission window. Visibly demanded keys outrank prefetch warming, and the
/// demand record is GATE-OWNED and COUNTED, bracketed here around each visible await
/// (`awaitVisibly`): `promote` opens a claim before awaiting, `demote` closes it when the await
/// ends — by the tile's cancellation (scroll-off) or by the generation completing. So the band a
/// generation queues in always reflects what is on screen NOW — not what was when it was
/// scheduled. Without the demote half, a fast scroll left every transiently mounted tile queued at
/// visible priority in mount order, and the tiles actually on screen drained LAST (the
/// fetches-start-from-the-top bug). Each host seeds its window from link class (LAN → 3,
/// WAN/unknown → 1 — WAN seeds narrow because 2 concurrent WAN demuxes were MEASURED WORSE over
/// VPN on 2026-07-10: bandwidth contention, lockstep timeouts each wasting a full download) and
/// then grows on completion success / shrinks on transport fault. Two hosts never share one
/// budget; a struggling link self-throttles without a hardcoded permanent cap.
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
    /// `await` (it hops to main for the actual decode). VLC is the default/fallback path;
    /// `avThumbnailer` is used only when `SMBPlaybackResolver.route` says the container is
    /// AVKit-eligible (same decision as playback).
    private let thumbnailer: VLCThumbnailer
    private let avThumbnailer: AVThumbnailer
    private let serverStore: ServerStore
    /// Shared warm-connection pool. Its cold-connect latency also classes the link (LAN/WAN), which
    /// seeds each host's AIMD admission window (WAN/unknown start narrow; LAN starts wider).
    private let pool: SMBSharePool

    /// Multi-permit, two-band gate with per-host AIMD admission — see the type doc. WAN seeds at 1
    /// from the 2026-07-10 2-permit-worse-over-VPN measurement; the window then adapts per host.
    private let gate = ThumbnailGate()

    /// At most one in-flight generation `Task` per key. A duplicate request awaits the existing task's
    /// value; the task removes its own entry on completion. Awaiting the task never cancels it.
    private var pending: [SMBThumbnailKey: Task<MediaArtwork, Never>] = [:]

    /// Hard ceiling for the WHOLE post-sidecar pipeline, anchored when cover-art / frame-grab
    /// work starts: the MKV cover-art extract, the container probe, an AV attempt and a VLC
    /// fallback all draw from this ONE budget (see `GenerationDeadline`) rather than each arming
    /// its own. 30s, not the thumbnailer's 20s default: over VPN a *successful* fetch measured
    /// 11.1s and several legitimate files timed out at 20s, so the default ceiling sat inside the
    /// observed success band. On LAN a fetch takes 1–3s, so only genuinely broken files ever pay
    /// this — and they're then backed off anyway.
    private static let generationTimeout: Duration = .seconds(30)

    /// Cap on the AVFoundation attempt WITHIN the generation budget. Stricter than the 30s total on
    /// purpose: the AV path exists because it's fast (moov + one keyframe); a wedge should fail over
    /// to VLC with budget left rather than sit for half a minute.
    private static let avGenerationTimeout: Duration = .seconds(15)

    /// Cap on the container probe WITHIN the generation budget — the same 4s deadline
    /// `SMBPlaybackResolver` gives its own probe.
    private static let probeTimeout: Duration = .seconds(4)

    /// Cap on the embedded cover-art extract WITHIN the generation budget. Metadata seeks are a
    /// handful of KiB when the SeekHead points cleanly; 6s is generous on LAN and still leaves the
    /// bulk of the 30s budget for a frame-grab fallback when the walk wedges over a bad link.
    private static let coverArtTimeout: Duration = .seconds(6)

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
        avThumbnailer: AVThumbnailer,
        serverStore: ServerStore,
        pool: SMBSharePool = SMBSharePool(),
        cache: SMBThumbnailCache = SMBThumbnailCache()
    ) {
        self.thumbnailer = thumbnailer
        self.avThumbnailer = avThumbnailer
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
    /// gate. Only a genuine miss coalesces onto gated generation, with a visible claim on the key
    /// held in the gate for the lifetime of this await (`awaitVisibly`) — the shared generation
    /// runs to completion either way, only its place in line changes.
    func artwork(for item: Item, ref: SMBServerRef, sidecar: SMBDirectoryEntry?) async -> MediaArtwork {
        guard let key = thumbnailKey(for: item, ref: ref) else { return .none }

        if let hit = await cache.existing(for: key) { return MediaArtwork(source: .local(hit.url), duration: hit.duration) }
        if await isNegativelyCached(key) { return .none }

        // A key another request already scheduled coalesces onto the pending task; only a genuine
        // first request schedules. Either way `awaitVisibly` opens the visible claim — for a
        // coalesced prefetch generation, `promote` also moves its already-queued waiter up.
        let generation = pending[key] ?? scheduleGeneration(key: key, item: item, ref: ref, sidecar: sidecar)
        return await awaitVisibly(generation, key: key)
    }

    /// Awaits a shared generation on behalf of a VISIBLE tile, holding a visible claim on `key` in
    /// the gate for exactly the await's lifetime: `promote` opens it; `demote` closes it on the
    /// tile's cancellation (scroll-off, item-identity change — the queued waiter then moves behind
    /// the tiles still on screen) or when the await returns. The generation itself is never
    /// cancelled (see the type doc).
    ///
    /// The claim is COUNTED in the gate, so the pairing survives unordered actor hops (a stale
    /// cancellation demote landing after a re-appearing tile's promote closes only its own claim).
    /// The two close paths RACE for one claim, though: a cancelled awaiter still returns when the
    /// generation finishes, so without the one-shot guard it would demote twice — and the extra
    /// close can strip a claim a concurrent awaiter of the same key opened, mis-banding a visible
    /// generation into the evictable prefetch backlog. Whichever path wins the lock closes; the
    /// loser is a no-op.
    private func awaitVisibly(_ task: Task<MediaArtwork, Never>, key: SMBThumbnailKey) async -> MediaArtwork {
        await gate.promote(key)
        let gate = gate
        let closed = OSAllocatedUnfairLock(initialState: false)
        @Sendable func closeClaim() async {
            let firstClose = closed.withLock { alreadyClosed in
                defer { alreadyClosed = true }
                return !alreadyClosed
            }
            if firstClose { await gate.demote(key) }
        }
        let value = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            // Runs at scroll-off; `gate`/`closed` are Sendable values, readable here.
            Task { await closeClaim() }
        }
        await closeClaim()
        return value
    }

    /// Warms a viewport-ahead SLICE of a browsed folder — the view hands over ~a dozen rows past the
    /// tile that just appeared, NOT the whole listing (explicit user policy, perception over
    /// completeness: scroll landings stay warm while a huge directory never fetches wall-to-wall).
    /// Schedules generation for the items not already cached / negatively-cached / pending — with
    /// no visible claim, so they queue in the prefetch band (yielding to visible tiles) — and does
    /// NOT await them. Runs on every link
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
            _ = scheduleGeneration(key: key, item: item, ref: ref, sidecar: sidecars[item.id])
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

    /// SMB playback-session thumbnail backfill entry point. Called from `PlayerViewModel` a few
    /// seconds into an SMB session that has no thumbnail yet. Checks the cache first so a file that
    /// already has one never pays for a frame capture; `captureFrame` is only invoked on a real
    /// miss. Best-effort throughout: any nil from `captureFrame`, or a storage failure, is a silent
    /// no-op — this must never surface an error to playback. A successful store also clears any
    /// persistent `.fail` marker (see `SMBThumbnailCache.store`), so a previously-failed file heals
    /// itself just by being watched. The movie→key recipe lives only here (via `thumbnailKey`) so
    /// the player never reimplements it.
    ///
    /// `captureFramePerformsIO` (from `PlaybackEngine.captureFramePerformsIO`) gates an I/O-issuing
    /// capture (AVKit) off non-LAN links: its fresh range reads queue on the SAME serialized bridge
    /// reader playback is pulling its next chunk from, so on WAN they contend for bandwidth the
    /// player needs more than the thumbnail does. VLC's capture reads no bytes at all and always
    /// runs, regardless of link class.
    func backfillThumbnail(
        item: Item,
        ref: SMBServerRef,
        duration: Duration?,
        captureFramePerformsIO: Bool,
        captureFrame: @Sendable () async -> Data?
    ) async {
        guard let key = thumbnailKey(for: item, ref: ref) else { return }
        // Cross-actor call into `SMBThumbnailCache` — needs await even from this actor.
        guard await cache.existing(for: key) == nil else { return }
        if captureFramePerformsIO, await pool.linkClass(host: ref.data.host) != .lan {
            return
        }
        guard let data = await captureFrame() else { return }
        _ = await cache.store(data, duration: duration, for: key)
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
    /// task runs to completion and clears its own `pending` entry. It carries NO band of its own:
    /// the gate's demand record decides visible-vs-prefetch when the generation reaches `wait`, and
    /// that record is owned entirely by the visible awaiters (`awaitVisibly`) — nothing to clean
    /// up here on completion.
    private func scheduleGeneration(
        key: SMBThumbnailKey, item: Item, ref: SMBServerRef, sidecar: SMBDirectoryEntry?
    ) -> Task<MediaArtwork, Never> {
        if let existing = pending[key] { return existing }
        let task = Task { [self] in
            let result = await generate(key: key, item: item, ref: ref, sidecar: sidecar)
            pending[key] = nil
            return result
        }
        pending[key] = task
        return task
    }

    // MARK: - Generation

    /// One full generation: read the link class, acquire a gate permit for this host (or bail if
    /// the bounded prefetch backlog evicted this waiter), run the held-permit pipeline
    /// (sidecar → cover-art → frame-grab), then release with a completion outcome that feeds the
    /// host's AIMD window. Never throws.
    private func generate(
        key: SMBThumbnailKey, item: Item, ref: SMBServerRef, sidecar: SMBDirectoryEntry?
    ) async -> MediaArtwork {
        // Link class seeds this host's admission window on first sight; subsequent admissions
        // adapt from completion outcomes (grow on success, shrink on transport fault).
        let host = ref.data.host
        let link = await pool.linkClass(host: host)

        guard await gate.wait(key: key, host: host, link: link) else {
            // Evicted from the bounded prefetch backlog (superseded by newer windows before any
            // permit): no SMB work happened, so record NOTHING — a visible request or a re-entered
            // window simply reschedules it (the pending entry clears in scheduleGeneration's tail).
            return .none
        }
        let (result, outcome) = await generateHoldingPermit(
            key: key, item: item, ref: ref, sidecar: sidecar, link: link)
        // No link class here: `link` was read before the (possibly minute-long) pipeline ran, and
        // the gate re-seeds only on a fresh arrival — see `ThumbnailGate.signal`.
        await gate.signal(host: host, outcome: outcome)
        return result
    }

    /// Runs under a held permit. Holds while a player owns the screen (the permit is kept), re-checks
    /// the disk + negative cache AFTER the hold (coalescing: a sibling's write or poisoning during a
    /// long session is seen on resume), assembles credentials once, then tries sidecar → cover-art
    /// (MKV) → frame-grab. Returns the artwork plus the completion outcome for the LAST tier
    /// that actually ran (exactly one `signal` per `wait`). Never throws.
    ///
    /// Exits that never touched the network report `.inconclusive`: they release the permit without
    /// pretending the link proved anything.
    private func generateHoldingPermit(
        key: SMBThumbnailKey, item: Item, ref: SMBServerRef, sidecar: SMBDirectoryEntry?,
        link: SMBLinkClass?
    ) async -> (MediaArtwork, ThumbnailFetchOutcome) {
        // Yield the uplink to playback first; the re-checks below run AFTER the hold.
        await awaitPlaybackIdle()

        if let hit = await cache.existing(for: key) {
            return (MediaArtwork(source: .local(hit.url), duration: hit.duration), .inconclusive)
        }
        if await isNegativelyCached(key) { return (.none, .inconclusive) }

        // Assemble credentials (the only Keychain read). A bad ItemID / unbuildable URL / lost
        // password slot is NOT a decode failure and says nothing about link health — don't poison,
        // and don't let a repeating credential failure grow the window on zero traffic.
        let ctx: SMBSourceContext
        do {
            ctx = try await SMBSourceResolver.context(for: item, ref: ref, serverStore: serverStore)
        } catch {
            return (.none, .inconclusive)
        }
        let fileName = (ctx.path as NSString).lastPathComponent

        // Sidecar tier first: a strict sibling image is a truer poster than a mid-file frame, and
        // reading + downscaling a small image is far cheaper than a demux. ANY sidecar failure falls
        // through WITHOUT poisoning the key; later tiers' outcomes are what reach `gate.signal`
        // (one signal per held permit). Transport-fault evidence from sidecar and cover-art OR
        // together so either earlier tier can still shrink the AIMD window when frame-grab is quiet.
        var earlierTierTransportFault = false
        if let sidecar {
            switch await trySidecar(sidecar: sidecar, ctx: ctx, ref: ref, key: key,
                                    fileName: fileName, link: link) {
            case .resolved(let art):
                return (art, .success)
            case .fellThrough(let transportFault):
                earlierTierTransportFault = transportFault
            }
        }

        // ONE ceiling shared by cover-art + frame-grab (probe / AV / VLC) — see `GenerationDeadline`.
        let deadline = GenerationDeadline(clock: clock, budget: Self.generationTimeout)
        // MKV only: WebM's element subset excludes Attachments entirely, so the walk would be
        // pure waste (a guaranteed-nil probe) on every .webm file.
        let ext = (ctx.path as NSString).pathExtension.lowercased()
        if ext == "mkv" {
            switch await tryCoverArt(
                ctx: ctx, ref: ref, key: key, fileName: fileName, link: link, deadline: deadline
            ) {
            case .resolved(let art):
                return (art, .success)
            case .fellThrough(let transportFault):
                earlierTierTransportFault = earlierTierTransportFault || transportFault
            }
        }

        let grab = await frameGrab(
            ctx: ctx, ref: ref, key: key, fileName: fileName, link: link, deadline: deadline)
        guard earlierTierTransportFault else { return (grab.artwork, grab.outcome) }
        // Earlier-tier reads are link evidence too, and used to be invisible to the window: a host
        // that timed out every sidecar/cover-art and then fell through looked perfectly healthy. A
        // frame-grab that actually PRODUCED a frame overrides it — the link demonstrably carried a
        // whole demux, so the earlier blip is stale news. Anything else and the earlier fault is
        // the best evidence this generation has. "Produced" means DECODED, not stored: a failed
        // disk write says nothing about the link that just carried the whole file.
        return (grab.artwork, grab.decodedAFrame ? .success : .transportFailure)
    }

    /// The sidecar tier: read the whole sibling image over a pooled reader (bounded by
    /// `withHardTimeout`), downscale to tile resolution, HEIC-encode, and store with no duration of
    /// its own (a poster has none; any length already cached for the key survives).
    /// Returns the resolved artwork on success, or a fall-through to the frame-grab. A fall-through
    /// is NEVER a poison — a missing/broken sidecar just means "use a frame-grab", not "this file is
    /// bad" — but it does carry whether the tier's own failure was LINK evidence, which the caller
    /// folds into the admission outcome.
    private func trySidecar(
        sidecar: SMBDirectoryEntry, ctx: SMBSourceContext, ref: SMBServerRef, key: SMBThumbnailKey,
        fileName: String, link: SMBLinkClass?
    ) async -> SidecarAttempt {
        let size = sidecar.size
        guard size > 0, size <= Self.maxSidecarBytes else { return .fellThrough(transportFault: false) }

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
                // A write failure — not a decode failure, and the read itself worked. Fall through
                // without poisoning and without blaming the link.
                Self.log.info("thumbnail sidecar store failed: \(fileName, privacy: .public) [\(Self.context(link), privacy: .public)] — frame-grab fallback")
                return .fellThrough(transportFault: false)
            }
            failures[key] = nil  // disk marker already cleared by store()
            Self.log.info("thumbnail generated: \(fileName, privacy: .public) [tier=sidecar \(Self.context(link), privacy: .public)] in \(elapsed.formattedSeconds, privacy: .public) (\(size.mibLabel, privacy: .public) read)")
            // A poster carries no video length, but the cache may already hold one for this exact
            // key (same size + mtime) from an earlier frame-grab — report what `store` actually
            // kept, so this tile doesn't lose a runtime label that a scroll-off/back would restore.
            return .resolved(MediaArtwork(source: .local(cached.url), duration: cached.duration))
        } catch {
            // A thrown read taints the borrow → discarded on disconnect (never returned to idle);
            // a reply timeout condemns instead.
            // The reader's own flag can't see the tier's HARD TIMEOUT — that fires OUTSIDE the read,
            // which is still stuck in libsmb2 — so the ceiling counts as link evidence in its own
            // right, exactly as `SMBFileSource.isTransportClass` treats it.
            let transportFault = await reader.hadTransportFault || error is HardTimeoutError
            await reader.disconnect()
            let elapsed = start.duration(to: clock.now)
            Self.log.info("thumbnail sidecar FELL THROUGH: \(fileName, privacy: .public) [tier=sidecar \(Self.context(link), privacy: .public)] after \(elapsed.formattedSeconds, privacy: .public) (\(String(describing: error), privacy: .public)) — frame-grab fallback")
            return .fellThrough(transportFault: transportFault)
        }
    }

    /// The MKV embedded cover-art tier: SeekHead (or pre-cluster linear scan) → Attachments
    /// → HEIC tile, sharing the generation deadline with the frame-grab that follows on fall-through.
    /// Poster-class downscale (`sidecarMaxPixel`) — cover art is not a frame grab.
    private func tryCoverArt(
        ctx: SMBSourceContext, ref: SMBServerRef, key: SMBThumbnailKey,
        fileName: String, link: SMBLinkClass?, deadline: GenerationDeadline
    ) async -> CoverArtAttempt {
        let reader: SMBShareReader = SMBRandomAccessReader(
            pool: pool, host: ref.data.host, username: ref.data.username, password: ctx.password,
            domain: ref.data.domain, share: ctx.share, path: ctx.path
        )
        let start = clock.now
        do {
            // Same race primitive the sidecar tier uses (`withHardTimeout`, below) rather than a
            // bespoke continuation: it cancels its own losing timer on a normal finish, so a fast
            // extract never leaves a sleeper parked for the rest of `coverArtTimeout`.
            let data = try await withHardTimeout(
                seconds: deadline.capped(at: Self.coverArtTimeout).fractionalSeconds
            ) {
                try await MatroskaCoverArt.extract(reader)
            }
            guard let data else {
                let elapsed = start.duration(to: clock.now)
                await reader.disconnect()
                Self.log.info("thumbnail coverart fell through: \(fileName, privacy: .public) [tier=coverart \(Self.context(link), privacy: .public)] after \(elapsed.formattedSeconds, privacy: .public) (no embedded cover art)")
                return .fellThrough(transportFault: false)
            }
            guard let image = ImageTranscode.downscaledImage(from: data, maxPixelSize: Self.sidecarMaxPixel) else {
                // Undecodable bytes — not a poison, not link evidence (mirrors sidecar).
                let elapsed = start.duration(to: clock.now)
                await reader.disconnect()
                Self.log.info("thumbnail coverart FELL THROUGH: \(fileName, privacy: .public) [tier=coverart \(Self.context(link), privacy: .public)] after \(elapsed.formattedSeconds, privacy: .public) (undecodable) — frame-grab fallback")
                return .fellThrough(transportFault: false)
            }
            let heic = try ImageTranscode.encodeHEIC(image)
            await reader.disconnect()
            let elapsed = start.duration(to: clock.now)
            guard let cached = await cache.store(heic, duration: nil, for: key) else {
                Self.log.info("thumbnail coverart store failed: \(fileName, privacy: .public) [\(Self.context(link), privacy: .public)] — frame-grab fallback")
                return .fellThrough(transportFault: false)
            }
            failures[key] = nil
            Self.log.info("thumbnail generated: \(fileName, privacy: .public) [tier=coverart \(Self.context(link), privacy: .public)] in \(elapsed.formattedSeconds, privacy: .public)")
            return .resolved(MediaArtwork(source: .local(cached.url), duration: cached.duration))
        } catch {
            let transportFault = await reader.hadTransportFault || error is HardTimeoutError
            if error is HardTimeoutError {
                // Wedged reader may still be parked in libsmb2 — fire-and-forget disconnect, same
                // idiom as frameGrab's nil-probe path. Don't await; don't build a replacement.
                Task { await reader.disconnect() }
            } else {
                await reader.disconnect()
            }
            let elapsed = start.duration(to: clock.now)
            Self.log.info("thumbnail coverart FELL THROUGH: \(fileName, privacy: .public) [tier=coverart \(Self.context(link), privacy: .public)] after \(elapsed.formattedSeconds, privacy: .public) (\(String(describing: error), privacy: .public)) — frame-grab fallback")
            return .fellThrough(transportFault: transportFault)
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
    ///
    /// `deadline` is the shared generation ceiling (cover-art already spent some of it when that
    /// tier ran); do not construct a fresh budget here.
    private func frameGrab(
        ctx: SMBSourceContext, ref: SMBServerRef, key: SMBThumbnailKey,
        fileName: String, link: SMBLinkClass?, deadline: GenerationDeadline
    ) async -> FrameGrabAttempt {
        func newReader() -> SMBShareReader {
            SMBRandomAccessReader(
                pool: pool, host: ref.data.host, username: ref.data.username, password: ctx.password,
                domain: ref.data.domain, share: ctx.share, path: ctx.path
            )
        }

        var reader = newReader()
        // Same probe → route sequencing as `SMBPlaybackResolver.resolve`, on the SAME reader the
        // bridge will own. `useBridge` means AVKit-eligible (hazard-free, complete, selector says
        // AVKit); otherwise stay on VLC. Size comes from the cache key when the listing had one
        // (`movie.size ?? 0` → 0 means unknown → nil).
        let probeResult = await SMBPlaybackResolver.probeWithDeadline(
            reader, seconds: deadline.capped(at: Self.probeTimeout).fractionalSeconds)
        if probeResult == nil {
            // The gate `SMBPlaybackResolver.resolve` applies, mirrored: a nil probe means the
            // deadline won (or the probe failed), so the reader may still have a native AMSMB2 call
            // sitting in libsmb2's poll loop — and handing THAT borrow to the bridge wedges the
            // bridge with it. Teardown is fire-and-forget for the resolver's reason (awaiting it
            // would serialize behind the very wedge the deadline just escaped) and routes into the
            // condemn machinery: `disconnect()` sees the in-flight op and parks the borrow instead
            // of returning it. The generation carries on over a FRESH reader — a nil probe always
            // routes to VLC, which needs no probe.
            let wedged = reader
            Task { await wedged.disconnect() }
            reader = newReader()
        }
        let sizeBytes: Int64? = key.size > 0 ? key.size : nil
        let (_, useAV) = SMBPlaybackResolver.route(probe: probeResult, sizeBytes: sizeBytes)

        // libvlc sniffs the container from the bytes; the advertised type is advisory only.
        let session = SMBBridgeSession(
            reader: reader, fileName: fileName, contentType: "application/octet-stream")
        let bridgeURL: URL
        do {
            // Loopback, not LAN: the thumbnailer is strictly on-device (no AirPlay), and a VPN's
            // policy layer resets self-connections to LAN/link-local addresses — the observed
            // "connection reset by peer" storm that broke generation over VPN. `start` tears the
            // session down itself on failure — a local bind failure is not a decode failure and
            // says nothing at all about the REMOTE host's link: don't poison, don't move the window.
            bridgeURL = try await session.start(scope: .loopback)
        } catch {
            return FrameGrabAttempt(artwork: .none, outcome: .inconclusive, decodedAFrame: false)
        }

        let result = await decodeAndStore(
            via: bridgeURL, session: session, key: key, fileName: fileName, link: link,
            useAV: useAV, deadline: deadline)
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
    ///
    /// When `useAV` is true (route said AVKit-eligible), try AVFoundation first, capped at
    /// `avGenerationTimeout` but never past what `deadline` has left. A transport-class fault aborts
    /// without VLC fallback and without poisoning (network blip, not a bad file). Any other AV
    /// failure falls back to VLC on the same bridge URL, spending the REST of the same budget. When
    /// `useAV` is false, VLC runs alone with the whole remainder.
    private func decodeAndStore(
        via bridgeURL: URL, session: SMBBridgeSession, key: SMBThumbnailKey, fileName: String,
        link: SMBLinkClass?, useAV: Bool, deadline: GenerationDeadline
    ) async -> FrameGrabAttempt {
        let start = clock.now
        // Hoisted out of the `do` so the FAILURE log names the tier that actually ran: a fall-through
        // that then failed in VLC is `framegrab-av+vlc`, exactly as the success path labels it.
        var tier = useAV ? "framegrab-av" : "framegrab"
        do {
            // SMB media is REMOTE: the thumbnailer's default 0.3 (30%-in) snapshot forces a deep
            // mid-file seek, and over the share a Matroska cluster read there repeatedly fails and
            // sometimes times out. So ask for an early frame DIRECTLY: 5% in is past a black leader but
            // shallow enough that the bytes are already streamed for the header. No vlcOptions: the
            // bridge URL needs none.
            let frame: VLCThumbnailFrame
            if useAV {
                do {
                    frame = try await avThumbnailer.thumbnailData(
                        for: bridgeURL, position: 0.05,
                        timeout: deadline.capped(at: Self.avGenerationTimeout))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Transport blip → don't blame the file, don't spend another 30s on VLC.
                    if await session.hadTransportFault {
                        let elapsed = start.duration(to: clock.now)
                        let stats = await session.stats
                        Self.log.info("thumbnail FAILED: \(fileName, privacy: .public) [tier=framegrab-av \(Self.context(link), privacy: .public)] after \(elapsed.formattedSeconds, privacy: .public) (AV transport fault, no VLC fallback; \(String(describing: error), privacy: .public), \(stats.formatted, privacy: .public))")
                        return FrameGrabAttempt(
                            artwork: .none, outcome: .transportFailure, decodedAFrame: false)
                    }
                    // Content-level AV miss (hazard probe didn't catch, AVFoundation quirk) → VLC.
                    Self.log.info("thumbnail AV fell through: \(fileName, privacy: .public) [tier=framegrab-av \(Self.context(link), privacy: .public)] (\(String(describing: error), privacy: .public)) — VLC fallback")
                    tier = "framegrab-av+vlc"
                    frame = try await thumbnailer.thumbnailData(
                        for: bridgeURL, position: 0.05, timeout: deadline.remaining)
                }
            } else {
                frame = try await thumbnailer.thumbnailData(
                    for: bridgeURL, position: 0.05, timeout: deadline.remaining)
            }
            let elapsed = start.duration(to: clock.now)
            let stats = await session.stats
            failures[key] = nil  // a decodable file: clear the in-memory stamp (store clears the disk marker)
            Self.log.info("thumbnail generated: \(fileName, privacy: .public) [tier=\(tier, privacy: .public) \(Self.context(link), privacy: .public)] in \(elapsed.formattedSeconds, privacy: .public) (\(stats.formatted, privacy: .public))")
            // A nil from store() is a WRITE failure, not a decode failure — return .none but do NOT
            // poison the key, so the next scroll retries instead of hiding a decodable file. The
            // frame still DECODED, which is what the link evidence is about: `decodedAFrame` stays
            // true so a sidecar blip earlier in the same generation is correctly overridden.
            guard let cached = await cache.store(frame.data, duration: frame.duration, for: key) else {
                return FrameGrabAttempt(artwork: .none, outcome: .success, decodedAFrame: true)
            }
            return FrameGrabAttempt(
                artwork: MediaArtwork(source: .local(cached.url), duration: cached.duration),
                outcome: .success,
                decodedAFrame: true
            )
        } catch {
            let elapsed = start.duration(to: clock.now)
            let transportFault = await session.hadTransportFault
            if Self.shouldRecordFailure(error: error, hadTransportFault: transportFault) {
                await recordFailure(key)
            }
            let stats = await session.stats
            Self.log.info("thumbnail FAILED: \(fileName, privacy: .public) [tier=\(tier, privacy: .public) \(Self.context(link), privacy: .public)] after \(elapsed.formattedSeconds, privacy: .public) (\(String(describing: error), privacy: .public), \(stats.formatted, privacy: .public))")
            // AIMD: shrink only when the LINK didn't keep up. Thumbnailer hard timeouts count too
            // (they fire on a struggling link even when no SMB read/attribute fault was recorded).
            // A cancelled generation is `.inconclusive` — nobody ever found out how the link was
            // doing, and reporting success there GREW the window on zero evidence. A content-level
            // miss is a real `.success`: the bytes arrived, the file just wouldn't decode.
            let outcome: ThumbnailFetchOutcome
            if error is CancellationError {
                outcome = .inconclusive
            } else if transportFault || Self.isThumbnailerTimeout(error) {
                outcome = .transportFailure
            } else {
                outcome = .success
            }
            return FrameGrabAttempt(artwork: .none, outcome: outcome, decodedAFrame: false)
        }
    }

    /// Whether a failed frame-grab should POISON the key (record a persistent failure marker).
    ///
    /// Only a content-level failure earns one. A transport-class SMB fault means the FILE may be
    /// perfectly fine — the network blipped — and a cancellation means nobody ever found out, so
    /// neither may blacklist a file for hours. Applies to pure-VLC, pure-AV, and AV→VLC-fallback
    /// outcomes alike, and is INDEPENDENT of the AIMD window outcome: poison and admission are
    /// separate axes (a content miss leaves the window alone but does poison; a blip is the
    /// reverse).
    ///
    /// `nonisolated static` and pure so the rule is testable without a share, a bridge, or a decode.
    nonisolated static func shouldRecordFailure(error: any Error, hadTransportFault: Bool) -> Bool {
        if error is CancellationError { return false }
        if hadTransportFault { return false }
        return true
    }

    /// Whether `error` is a thumbnailer's own "gave up waiting" shape — distinct from content-side
    /// cases like `encodingFailed`. Used only for AIMD admission feedback; the poison guard does
    /// not consult this (it already has `hadTransportFault` + cancellation).
    private static func isThumbnailerTimeout(_ error: any Error) -> Bool {
        if let error = error as? VLCThumbnailError {
            switch error {
            case .timedOut, .parseTimedOut: return true
            case .encodingFailed: return false
            }
        }
        if let error = error as? AVThumbnailError {
            switch error {
            case .timedOut: return true
            case .encodingFailed: return false
            }
        }
        return false
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
            playbackWaiters.add(key: nil, host: nil, continuation)
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

    /// `link=wan` — the shared diagnostic context fragment for the outcome logs. Permit counts are
    /// per-host adaptive state inside the gate, not a static fact of link class, so they are not
    /// fabricated here.
    private static func context(_ link: SMBLinkClass?) -> String {
        "link=\(linkLabel(link))"
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

/// What the sidecar tier produced: a poster, or a fall-through to the frame-grab that also reports
/// whether the tier's own failure was LINK evidence (a transport-class read fault or the tier's hard
/// timeout) rather than a missing/broken image.
///
/// `nonisolated` for the same app-target MainActor-default reason as `WaiterList` — it is produced
/// and consumed inside the `MediaArtworkProvider` actor.
nonisolated private enum SidecarAttempt {
    case resolved(MediaArtwork)
    case fellThrough(transportFault: Bool)
}

/// What the MKV cover-art tier produced: a poster from an embedded attachment, or a fall-through
/// to the frame-grab that also reports whether the tier's own failure was LINK evidence (a
/// transport-class read fault or the tier's hard timeout) rather than absent/undecodable cover art.
///
/// `nonisolated` for the same app-target MainActor-default reason as `WaiterList`.
nonisolated private enum CoverArtAttempt {
    case resolved(MediaArtwork)
    case fellThrough(transportFault: Bool)
}

/// What the frame-grab tier produced: the artwork, the admission outcome, and — separately —
/// whether a frame actually came back from the DECODER.
///
/// "Decoded" and "stored" are different facts. A decode that succeeded but whose disk write failed
/// returns `.none` artwork, and reading that as "no frame" made a failed write look like link
/// trouble to the earlier-tier-fault override above. The write is local; only the decode says the
/// link carried the file.
///
/// `nonisolated` for the same app-target MainActor-default reason as `WaiterList`.
nonisolated private struct FrameGrabAttempt {
    let artwork: MediaArtwork
    let outcome: ThumbnailFetchOutcome
    let decodedAFrame: Bool
}

/// The ONE ceiling cover-art + frame-grab draw from, anchored in `generateHoldingPermit` before
/// either tier runs.
///
/// The cover-art extract, the probe, an AV attempt and a VLC fallback used to (or would) arm
/// INDEPENDENT ceilings and run in series under a single held permit — well past the 30s budget,
/// with the whole host's admission slot blocked for all of it. They now draw from this shared
/// budget: each phase asks for its own cap or whatever is left, whichever is smaller, so the total
/// can never exceed the budget however the phases fall out.
///
/// `nonisolated` for the same app-target MainActor-default reason as `WaiterList`.
nonisolated private struct GenerationDeadline {
    private let clock: ContinuousClock
    private let expiry: ContinuousClock.Instant

    init(clock: ContinuousClock, budget: Duration) {
        self.clock = clock
        self.expiry = clock.now.advanced(by: budget)
    }

    /// Budget left, never negative. An exhausted budget hands the next phase `.zero`, which its own
    /// timeout treats as an immediate expiry — the honest answer when there is nothing left to spend.
    var remaining: Duration {
        max(.zero, clock.now.duration(to: expiry))
    }

    /// `cap`, or the remaining budget when that is smaller.
    func capped(at cap: Duration) -> Duration {
        min(cap, remaining)
    }
}

nonisolated private extension Duration {
    /// "12.3s" — for the thumbnail outcome logs.
    var formattedSeconds: String {
        String(format: "%.1fs", fractionalSeconds)
    }
}

nonisolated private extension Int64 {
    /// "4.2 MiB" — fixed-format binary-MiB label shared by every outcome-log byte count
    /// (grep-able diagnostics, not UI — locale-aware `.byteCount` would vary separators/units).
    var mibLabel: String {
        String(format: "%.1f MiB", Double(self) / 1_048_576)
    }
}

nonisolated private extension SMBHTTPBridge.Stats {
    /// "4.2 MiB over 12 connections" — what a frame-grab cost the share, for the outcome logs.
    var formatted: String {
        "\(Int64(bytesRead).mibLabel) over \(connections) connections"
    }
}

// The gate and its waiter bookkeeping live in `ThumbnailGate.swift`.
