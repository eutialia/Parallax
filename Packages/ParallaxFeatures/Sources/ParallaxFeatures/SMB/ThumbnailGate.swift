import Foundation
import ParallaxFileBrowse

/// FIFO list of continuation waiters, keyed by an optional generation key and host (both nil for
/// the playback hold, which is key- and host-agnostic). A waiter carries NO link class: the class
/// only ever seeds a host's window, and that seeding happens once at arrival in
/// `ThumbnailGate.wait` — a class baked into a queued waiter would be stale by the time it is read.
/// A value type
/// owned by an actor: every mutation runs under that actor's isolation, so the stored
/// `CheckedContinuation`s never cross an isolation boundary. Continuations resume with a Bool —
/// true = proceed (permit granted / hold released), false = ABANDONED (evicted from the bounded
/// prefetch backlog; the generation bails without SMB work). Shared by `ThumbnailGate` and
/// `MediaArtworkProvider`'s playback hold so the FIFO bookkeeping exists once.
///
/// Marked `nonisolated` at the type level because the app target defaults every declaration to
/// `@MainActor` — without it, the gate actor's synchronous calls into this value type inherit a
/// main-actor isolation inference that is wrong (the gate is not main) and produces a cascade of
/// isolation warnings. Same precedent as `SMBThumbnailKey`.
nonisolated struct WaiterList {
    typealias Waiter = (
        key: SMBThumbnailKey?,
        host: String?,
        continuation: CheckedContinuation<Bool, Never>
    )

    private var waiters: [Waiter] = []

    var count: Int { waiters.count }

    mutating func add(
        key: SMBThumbnailKey?,
        host: String?,
        _ continuation: CheckedContinuation<Bool, Never>
    ) {
        waiters.append((key, host, continuation))
    }

    /// Removes and returns the first waiter whose host passes `admissible`, or nil. FIFO within
    /// the admissible subset — a waiter blocked by its own host's window is skipped, not
    /// head-of-line blocking waiters for other hosts behind it.
    mutating func removeFirst(where admissible: (String?) -> Bool) -> Waiter? {
        guard let index = waiters.firstIndex(where: { admissible($0.host) }) else { return nil }
        return waiters.remove(at: index)
    }

    /// Removes and returns the OLDEST waiter unconditionally (the prefetch-backlog eviction), or nil.
    mutating func removeOldest() -> Waiter? {
        waiters.isEmpty ? nil : waiters.removeFirst()
    }

    /// Removes the first waiter matching `key` (for band moves), or nil.
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

/// Outcome of one completed generation, fed back into the host's admission window: a transport
/// fault shrinks it (the link didn't keep up); a clean success OR a content-level decode failure is
/// `.success`, because the LINK behaved fine even when the file didn't; and `.inconclusive` moves
/// the window NOT AT ALL, for the exits that never touched the network — or never finished.
///
/// The third case exists because "released the permit" and "learned something about the link" are
/// different facts. A cache hit found after the playback hold, a lost Keychain slot, a local
/// loopback bind failure, a cancelled decode — none of them proved anything, and reporting them as
/// `.success` grew the window on zero evidence (a repeating credential failure could pump a WAN
/// host to the ceiling without ever reading a file).
///
/// `nonisolated` for the same app-target MainActor-default reason as `WaiterList` — this value is
/// produced off the main actor inside `MediaArtworkProvider` and fed into the gate actor.
nonisolated enum ThumbnailFetchOutcome: Sendable {
    case success
    case transportFailure
    case inconclusive
}

/// One host's admission window plus the link class it was SEEDED from. The seed is stored because
/// a host's class can change mid-session — see `ThumbnailGate.seed(host:link:)`.
///
/// `nonisolated` for the same app-target MainActor-default reason as `WaiterList`.
nonisolated private struct HostAdmission {
    var window: SMBAdmissionWindow
    var seed: SMBLinkClass?
}

/// Multi-permit, two-band async gate bounding concurrent SMB thumbnail work with a per-host
/// AIMD admission window.
///
/// Admission is COMPLETION-DRIVEN and PER HOST: each host seeds an `SMBAdmissionWindow` from its
/// link class (LAN → 3, WAN/unknown → 1) and then grows on `.success` signals / shrinks on
/// `.transportFailure`. WAN seeds narrow because 2 concurrent WAN demuxes were measured worse
/// over VPN (2026-07-10: bandwidth contention, lockstep timeouts each wasting a full 10+ MB
/// download) — that measurement is the *starting point*, not a permanent pin; a recovering link
/// still climbs when completions succeed. Two hosts never share one budget: a struggling WAN NAS
/// cannot starve a fast LAN host, and a fast host's growth cannot widen the gate under a live
/// fetch on a different host.
///
/// A settable global limit was rejected earlier for a related reason (last-writer-wins under mixed
/// classes); per-host adaptive windows solve the same pathology without a hardcoded permanent
/// wan-serialization rule.
///
/// Two FIFO waiter bands: keys a tile VISIBLY demands are admitted before prefetch warming. The
/// band is decided HERE, at enqueue, from the gate-owned demand record — never declared by the
/// caller. The record is a COUNT, not a set: `promote(key)` opens a visible claim (and moves an
/// already-queued prefetch waiter up); `demote(key)` closes one, moving a queued visible waiter
/// back down only when the LAST claim is withdrawn. Counting makes an unordered promote/demote
/// pair commute — the demote for a scrolled-off tile is a fire-and-forget hop, so it can land
/// AFTER the re-appearing tile's promote; with a set that stale demote stripped the live claim,
/// with a count it just closes the claim it was paired with. Gate ownership closes both sides of
/// the schedule→wait window: a generation that hasn't reached `wait` yet still lands in the right
/// band when it gets there, whichever way the demand flipped in between. Without `demote`, a fast
/// scroll once left every transiently mounted tile's request in the visible band FOREVER —
/// unbounded and FIFO, so thumbnails drained in listing order and the tiles actually on screen at
/// the bottom waited behind the entire scrolled-past backlog (the "fetches always start from the
/// top" bug).
actor ThumbnailGate {
    /// Ceiling on QUEUED prefetch waiters. Prefetch windows accumulate across folders (generations
    /// are never cancelled), so without a bound a drill-through-many-folders session queues stale
    /// work that saturates a WAN link for minutes after the user left. Beyond the cap, the OLDEST
    /// queued prefetch waiter is resumed as ABANDONED (false) — it did no SMB work, records no
    /// failure, and a visible request or a re-entered window simply reschedules it. Roughly one
    /// window's worth: newer windows describe where the user actually is. Demoted waiters land at
    /// the band's tail and count against the same cap, so scrolled-past backlog ages out here too.
    private static let maxQueuedPrefetch = 24

    /// SAFETY BOUND on concurrent generations across ALL hosts — not an operating cap. Per-host
    /// AIMD owns the operating point and normally sits well under this; the bound only stops two
    /// or three healthy hosts' windows from stacking (2 hosts at the per-host ceiling is already 8
    /// simultaneous bridges + demuxes, and generations are never cancelled, so every one of them
    /// runs to the end).
    private static let maxGlobalInFlight = 6

    /// Per-host AIMD windows, each remembering the link class it was seeded from. Lazily seeded on
    /// first `wait`/`signal` for that host.
    private var windows: [String: HostAdmission] = [:]
    /// In-flight permit count per host. Entries are removed at zero so departed hosts don't linger.
    private var inFlight: [String: Int] = [:]
    private var visible = WaiterList()
    private var prefetch = WaiterList()
    /// Open visible claims per key: `promote` opens one, `demote` closes one; the entry is removed
    /// (never kept at zero) when the last claim closes. Consulted at enqueue so a late-arriving
    /// waiter lands in the band the current demand says — not the one that was true when its
    /// generation was scheduled.
    private var visibleClaims: [SMBThumbnailKey: Int] = [:]

    /// Acquires a permit for `host`, suspending (FIFO within the band) until that host's window
    /// has a free slot. The band is read from the gate-owned demand record at enqueue — callers
    /// declare nothing. Returns true with the permit held, or false when the waiter was evicted
    /// from the bounded prefetch backlog — the caller must bail without SMB work and WITHOUT
    /// `signal`ing (no permit was granted).
    ///
    /// This is the ONLY place a host's window is seeded or re-seeded: an arrival is a real event
    /// carrying the class the pool believes RIGHT NOW. Everything else (admission scans, the
    /// completion feedback in `signal`) reads the stored window and never writes a seed.
    func wait(key: SMBThumbnailKey, host: String, link: SMBLinkClass?) async -> Bool {
        seed(host: host, link: link)
        if admissible(host: host) {
            account(host: host)
            return true
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            if visibleClaims[key] != nil {
                visible.add(key: key, host: host, continuation)
            } else {
                addPrefetch(key: key, host: host, continuation)
            }
        }
        // Resumed by `admit` (true; permit already accounted) or backlog eviction (false).
    }

    /// Releases a held permit for `host`, feeds `outcome` into that host's STORED admission window,
    /// and re-checks waiters — a freed slot OR a just-grown window can both open admission.
    ///
    /// Takes no link class on purpose. A generation bakes its class when it starts, so by the time
    /// it completes that class can be minutes stale; re-seeding from it would let a long LAN
    /// generation finishing after a VPN came up restore the wide LAN window the newest arrival had
    /// just narrowed. The outcome applies to whatever window the host has now, whoever seeded it.
    func signal(host: String, outcome: ThumbnailFetchOutcome) {
        let next = (inFlight[host] ?? 0) - 1
        if next <= 0 {
            inFlight[host] = nil
        } else {
            inFlight[host] = next
        }
        // No stored window means no `wait` ever seeded this host, so there is nothing to feed —
        // release the permit and re-check waiters anyway.
        if var entry = windows[host] {
            switch outcome {
            case .success:
                entry.window.recordSuccess()
            case .transportFailure:
                entry.window.recordTransportFailure()
            case .inconclusive:
                break  // the permit is released and admission re-runs, but the window learned nothing
            }
            windows[host] = entry
        }
        admit()
    }

    /// Opens a visible claim on `key` and moves an already-queued prefetch waiter for it to the
    /// visible band. Safe to call before the key's generation reaches `wait` — the recorded claim
    /// is consulted at enqueue, closing that race. (No `admit` here: moving bands frees no permit.)
    func promote(_ key: SMBThumbnailKey) {
        let claims = (visibleClaims[key] ?? 0) + 1
        visibleClaims[key] = claims
        guard claims == 1, let waiter = prefetch.removeWaiter(key: key) else { return }
        visible.add(key: key, host: waiter.host, waiter.continuation)
    }

    /// Closes one visible claim: a tile that wanted `key` stopped waiting (scroll-off, or its
    /// await completed). Counted reverse of `promote`, safe against a claim already closed (a
    /// late demote after the generation finished is a no-op): only when the LAST claim closes does
    /// the queued visible waiter move to the prefetch band's TAIL, behind everything the user
    /// still wants — where the bounded backlog's eviction ages it out under pressure. The
    /// generation itself is never cancelled; only its place in line changes.
    func demote(_ key: SMBThumbnailKey) {
        guard let claims = visibleClaims[key] else { return }
        guard claims == 1 else {
            visibleClaims[key] = claims - 1
            return
        }
        visibleClaims[key] = nil
        guard let waiter = visible.removeWaiter(key: key) else { return }
        addPrefetch(key: key, host: waiter.host, waiter.continuation)
    }

    /// Queued waiter counts per band — test introspection only (the tests poll these to sequence
    /// suspensions deterministically); production code never reads them.
    func queueDepths() -> (visible: Int, prefetch: Int) {
        (visible.count, prefetch.count)
    }

    /// Appends to the prefetch band and applies the backlog cap, evicting the OLDEST waiter as
    /// abandoned when over. Shared by `wait` (fresh enqueue) and `demote` (band move).
    private func addPrefetch(
        key: SMBThumbnailKey,
        host: String?,
        _ continuation: CheckedContinuation<Bool, Never>
    ) {
        prefetch.add(key: key, host: host, continuation)
        if prefetch.count > Self.maxQueuedPrefetch, let evicted = prefetch.removeOldest() {
            evicted.continuation.resume(returning: false)
        }
    }

    /// Whether `host` has a free slot under its STORED admission window AND the global safety bound
    /// has room. A PURE READ — it never seeds, because it runs from the admission scan too, where
    /// "is this waiter admissible?" must not double as "reclassify this host".
    private func admissible(host: String) -> Bool {
        guard inFlight.values.reduce(0, +) < Self.maxGlobalInFlight else { return false }
        return (inFlight[host] ?? 0) < (windows[host]?.window.limit ?? Self.unseededLimit)
    }

    /// What a host with no stored window is allowed. Unreachable in practice — `wait` seeds before
    /// it asks — it just keeps the read total instead of trapping.
    private static let unseededLimit = SMBAdmissionWindow(seed: nil).limit

    private func account(host: String) {
        inFlight[host, default: 0] += 1
    }

    /// Seeds `host`'s window on first sight, and RE-seeds it when the link class has changed.
    /// Called only from `wait`, on a real arrival.
    ///
    /// A host's link class is not fixed for the session: turning a VPN on mid-scroll makes the pool
    /// re-class a LAN host as `.wan`, and a window that had grown to the ceiling on the fast link
    /// would otherwise keep that width over the slow one — AIMD would only claw it back one
    /// transport fault at a time, each fault costing a wasted multi-MB download. A non-nil class
    /// that DIFFERS from the seed is therefore treated as new evidence and re-seeds the window. A
    /// nil class is NOT: it means "not classified yet", not "the class changed", so it keeps
    /// whatever the earlier evidence built.
    private func seed(host: String, link: SMBLinkClass?) {
        if let existing = windows[host] {
            guard let link, link != existing.seed else { return }
        }
        windows[host] = HostAdmission(window: SMBAdmissionWindow(seed: link), seed: link)
    }

    /// Hands out permits to waiting generations while any waiter's own host is admissible: visible
    /// band first, then prefetch, skipping over waiters whose host window is full (a blocked host
    /// does not head-of-line-block other hosts behind it). Each admitted waiter's permit is
    /// accounted here (its `wait` won't re-account).
    ///
    /// A host-less waiter is simply never admissible. Only the playback hold enqueues one, and that
    /// `WaiterList` is a different list entirely — so this is a shape the bands can't hold, not an
    /// invariant worth trapping on inside the admission loop.
    private func admit() {
        while true {
            guard let waiter = visible.removeFirst(where: hasFreeSlot)
                    ?? prefetch.removeFirst(where: hasFreeSlot) else { break }
            guard let host = waiter.host else {
                // Unreachable (the predicate excluded it) — resume as ABANDONED rather than
                // leaking a suspended continuation.
                waiter.continuation.resume(returning: false)
                continue
            }
            account(host: host)
            waiter.continuation.resume(returning: true)
        }
    }

    /// `admissible`, over the optional host a queued waiter carries. Pure, like everything it calls.
    private func hasFreeSlot(host: String?) -> Bool {
        guard let host else { return false }
        return admissible(host: host)
    }
}
