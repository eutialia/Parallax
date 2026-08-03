import Foundation
import ParallaxFileBrowse

/// FIFO list of continuation waiters, keyed by an optional generation key and the waiter's link
/// class (both nil for the playback hold, which is key- and class-agnostic). A value type owned by
/// an actor: every mutation runs under that actor's isolation, so the stored `CheckedContinuation`s
/// never cross an isolation boundary. Continuations resume with a Bool — true = proceed (permit
/// granted / hold released), false = ABANDONED (evicted from the bounded prefetch backlog; the
/// generation bails without SMB work). Shared by `ThumbnailGate` and `MediaArtworkProvider`'s
/// playback hold so the FIFO bookkeeping exists once.
struct WaiterList {
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

/// Multi-permit, two-band async gate bounding concurrent SMB thumbnail work, with link-class-
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
    private static let maxConcurrent = 3
    /// Ceiling on QUEUED prefetch waiters. Prefetch windows accumulate across folders (generations
    /// are never cancelled), so without a bound a drill-through-many-folders session queues stale
    /// work that saturates a WAN link for minutes after the user left. Beyond the cap, the OLDEST
    /// queued prefetch waiter is resumed as ABANDONED (false) — it did no SMB work, records no
    /// failure, and a visible request or a re-entered window simply reschedules it. Roughly one
    /// window's worth: newer windows describe where the user actually is. Demoted waiters land at
    /// the band's tail and count against the same cap, so scrolled-past backlog ages out here too.
    private static let maxQueuedPrefetch = 24

    private var inFlight = 0
    /// WAN/unknown-classed permits currently held — `admissible` caps this at 1.
    private var wanInFlight = 0
    private var visible = WaiterList()
    private var prefetch = WaiterList()
    /// Open visible claims per key: `promote` opens one, `demote` closes one; the entry is removed
    /// (never kept at zero) when the last claim closes. Consulted at enqueue so a late-arriving
    /// waiter lands in the band the current demand says — not the one that was true when its
    /// generation was scheduled.
    private var visibleClaims: [SMBThumbnailKey: Int] = [:]

    /// Acquires a permit, suspending (FIFO within the band) until admissible. The band is read
    /// from the gate-owned demand record at enqueue — callers declare nothing. Returns true with
    /// the permit held, or false when the waiter was evicted from the bounded prefetch backlog —
    /// the caller must bail without SMB work and WITHOUT `signal`ing (no permit was granted).
    func wait(key: SMBThumbnailKey, link: SMBLinkClass?) async -> Bool {
        if admissible(link) {
            account(link)
            return true
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            if visibleClaims[key] != nil {
                visible.add(key: key, link: link, continuation)
            } else {
                addPrefetch(key: key, link: link, continuation)
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

    /// Opens a visible claim on `key` and moves an already-queued prefetch waiter for it to the
    /// visible band. Safe to call before the key's generation reaches `wait` — the recorded claim
    /// is consulted at enqueue, closing that race. (No `admit` here: moving bands frees no permit.)
    func promote(_ key: SMBThumbnailKey) {
        let claims = (visibleClaims[key] ?? 0) + 1
        visibleClaims[key] = claims
        guard claims == 1, let waiter = prefetch.removeWaiter(key: key) else { return }
        visible.add(key: key, link: waiter.link, waiter.continuation)
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
        addPrefetch(key: key, link: waiter.link, waiter.continuation)
    }

    /// Queued waiter counts per band — test introspection only (the tests poll these to sequence
    /// suspensions deterministically); production code never reads them.
    func queueDepths() -> (visible: Int, prefetch: Int) {
        (visible.count, prefetch.count)
    }

    /// Appends to the prefetch band and applies the backlog cap, evicting the OLDEST waiter as
    /// abandoned when over. Shared by `wait` (fresh enqueue) and `demote` (band move).
    private func addPrefetch(key: SMBThumbnailKey, link: SMBLinkClass?, _ continuation: CheckedContinuation<Bool, Never>) {
        prefetch.add(key: key, link: link, continuation)
        if prefetch.count > Self.maxQueuedPrefetch, let evicted = prefetch.removeOldest() {
            evicted.continuation.resume(returning: false)
        }
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
