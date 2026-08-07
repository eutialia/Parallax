import Foundation
import Testing
import ParallaxFileBrowse
@testable import Parallax

/// `ThumbnailGate` scheduling policy: per-host AIMD admission windows, the gate-owned
/// visible/prefetch banding (counted `promote`/`demote` claims decide the band at enqueue —
/// callers declare nothing), and the bounded prefetch backlog. These are the invariants behind
/// the "visible tiles are served before scrolled-past backlog" behavior, exercised directly on
/// the gate — no SMB, no provider. The time limit is the anti-hang net for the suite's awaits on
/// gate continuations: a regression that never resumes a waiter fails its own test instead of
/// wedging the run (it sits above the CI-scaled `waitUntil` ceiling, which stays the first
/// reporter).
@Suite("ThumbnailGate", .timeLimit(.minutes(3)))
struct ThumbnailGateTests {

    private let testHost = "host"

    private func key(_ path: String) -> SMBThumbnailKey {
        SMBTestFixtures.thumbnailKey(path: path)
    }

    /// Order-of-admission recorder shared by the queued waiters.
    private actor Admissions {
        var order: [String] = []
        func record(_ name: String) { order.append(name) }
    }

    /// Fills all 3 LAN permits for `host` so every subsequent `wait` on that host queues.
    /// LAN seeds a window of 3.0 → limit 3; a success signal on that seed grows the float but
    /// does not change the integer limit, so banding tests can release with `.success` safely.
    private func fillPermits(_ gate: ThumbnailGate, host: String = "host") async {
        for i in 0..<3 {
            #expect(await gate.wait(key: key("holder-\(i)"), host: host, link: .lan))
        }
    }

    @Test("three LAN permits admit immediately; the fourth queues")
    func permitCapacity() async {
        let gate = ThumbnailGate()
        await fillPermits(gate)

        let queued = Task { await gate.wait(key: key("fourth"), host: testHost, link: .lan) }
        await waitUntil("fourth wait should queue") {
            await gate.queueDepths().prefetch == 1
        }

        await gate.signal(host: testHost, outcome: .success)
        #expect(await queued.value)
    }

    @Test("a promoted key is admitted before earlier-queued prefetch waiters")
    func visibleBandOutranksPrefetch() async {
        let gate = ThumbnailGate()
        let admissions = Admissions()
        await fillPermits(gate)

        // Prefetch waiter first (FIFO would serve it first) …
        let warm = Task {
            _ = await gate.wait(key: key("warm"), host: testHost, link: .lan)
            await admissions.record("warm")
        }
        await waitUntil("prefetch waiter should queue") { await gate.queueDepths().prefetch == 1 }

        // … then a visibly demanded key, enqueued AFTER but admitted FIRST.
        await gate.promote(key("seen"))
        let seen = Task {
            _ = await gate.wait(key: key("seen"), host: testHost, link: .lan)
            await admissions.record("seen")
        }
        await waitUntil("visible waiter should queue") { await gate.queueDepths().visible == 1 }

        await gate.signal(host: testHost, outcome: .success)
        await waitUntil("visible waiter should admit first") { await admissions.order == ["seen"] }
        await gate.signal(host: testHost, outcome: .success)
        _ = await (seen.value, warm.value)
        #expect(await admissions.order == ["seen", "warm"])
    }

    @Test("demote moves a queued visible waiter behind the prefetch band")
    func demoteReordersBehindPrefetch() async {
        let gate = ThumbnailGate()
        let admissions = Admissions()
        await fillPermits(gate)

        // A visible waiter from a tile that will scroll off …
        await gate.promote(key("gone"))
        let gone = Task {
            _ = await gate.wait(key: key("gone"), host: testHost, link: .lan)
            await admissions.record("gone")
        }
        await waitUntil("visible waiter should queue") { await gate.queueDepths().visible == 1 }

        // … an unrelated prefetch waiter behind it …
        let warm = Task {
            _ = await gate.wait(key: key("warm"), host: testHost, link: .lan)
            await admissions.record("warm")
        }
        await waitUntil("prefetch waiter should queue") { await gate.queueDepths().prefetch == 1 }

        // … then the scroll-off: the visible waiter joins the prefetch TAIL.
        await gate.demote(key("gone"))
        await waitUntil("demoted waiter should move bands") {
            await gate.queueDepths() == (visible: 0, prefetch: 2)
        }

        await gate.signal(host: testHost, outcome: .success)
        await waitUntil("older prefetch admits first") { await admissions.order == ["warm"] }
        await gate.signal(host: testHost, outcome: .success)
        _ = await (gone.value, warm.value)
        #expect(await admissions.order == ["warm", "gone"])
    }

    @Test("the demand record decides the band at enqueue, both directions", arguments: [true, false])
    func gateOwnedBanding(demandWithdrawn: Bool) async {
        let gate = ThumbnailGate()
        await fillPermits(gate)

        // The demand flips BEFORE the generation reaches `wait` — the exact schedule→wait
        // window the record exists for (a declared priority would be stale by now).
        await gate.promote(key("k"))
        if demandWithdrawn { await gate.demote(key("k")) }

        let queued = Task { await gate.wait(key: key("k"), host: testHost, link: .lan) }
        await waitUntil("waiter should land in the band the record says") {
            let depths = await gate.queueDepths()
            return demandWithdrawn ? depths == (0, 1) : depths == (1, 0)
        }
        await gate.signal(host: testHost, outcome: .success)
        #expect(await queued.value)
    }

    @Test("claims are counted: one demote against two promotes keeps the key visible")
    func countedClaimsCommute() async {
        let gate = ThumbnailGate()
        await fillPermits(gate)

        // The scroll-bounce shape: a tile's claim, its scroll-off demote delayed past the
        // re-appearing tile's second promote. With a set-based record the late demote stripped
        // the live claim; counting keeps the key visible until the LAST claim closes.
        await gate.promote(key("k"))
        await gate.promote(key("k"))
        await gate.demote(key("k"))

        let queued = Task { await gate.wait(key: key("k"), host: testHost, link: .lan) }
        await waitUntil("one open claim should still queue visible") {
            await gate.queueDepths() == (visible: 1, prefetch: 0)
        }

        // Closing the last claim moves the queued waiter down; a further demote is a no-op.
        await gate.demote(key("k"))
        await waitUntil("last close should move the waiter to prefetch") {
            await gate.queueDepths() == (visible: 0, prefetch: 1)
        }
        await gate.demote(key("k"))
        #expect(await gate.queueDepths() == (visible: 0, prefetch: 1))

        await gate.signal(host: testHost, outcome: .success)
        #expect(await queued.value)
    }

    @Test("the prefetch backlog evicts its oldest waiter as abandoned beyond the cap")
    func prefetchBacklogEviction() async {
        let gate = ThumbnailGate()
        await fillPermits(gate)

        // First in — the one the over-cap enqueue must evict (resumed `false`, no permit).
        let oldest = Task { await gate.wait(key: key("prefetch-0"), host: testHost, link: .lan) }
        await waitUntil("oldest should queue") { await gate.queueDepths().prefetch == 1 }

        // Fill to the cap exactly (24 queued including `oldest`) — no eviction yet.
        var later: [Task<Bool, Never>] = []
        for i in 1...23 {
            later.append(Task { await gate.wait(key: key("prefetch-\(i)"), host: testHost, link: .lan) })
            await waitUntil("waiter \(i) should queue") {
                await gate.queueDepths().prefetch == i + 1
            }
        }

        // The 25th enqueue crosses the cap: the oldest is resumed as ABANDONED, depth stays 24.
        later.append(Task { await gate.wait(key: key("prefetch-24"), host: testHost, link: .lan) })
        #expect(await oldest.value == false)
        await waitUntil("depth should settle at the cap") { await gate.queueDepths().prefetch == 24 }

        // Drain so no waiter leaks a suspended continuation past the test.
        for _ in 0..<24 { await gate.signal(host: testHost, outcome: .success) }
        for task in later { #expect(await task.value) }
    }

    @Test("completion outcomes grow/shrink a host's window; a second host is independent")
    func perHostAIMDAdmission() async {
        let gate = ThumbnailGate()
        let wanHost = "wan-nas"
        let lanHost = "lan-nas"

        // --- WAN seed of 1 stays serialized until a success grows past 1 ---
        #expect(await gate.wait(key: key("wan-1"), host: wanHost, link: .wan))

        let wan2 = Task {
            await gate.wait(key: key("wan-2"), host: wanHost, link: .wan)
        }
        await waitUntil("second WAN wait on same host should queue") {
            await gate.queueDepths().prefetch == 1
        }

        // One success: window 1.0 → 2.0 (limit 2); admit() resumes wan-2 (inFlight becomes 1).
        await gate.signal(host: wanHost, outcome: .success)
        await waitUntil("success should admit the queued WAN waiter") {
            await gate.queueDepths().prefetch == 0
        }
        #expect(await wan2.value)

        // Third wait admits immediately (inFlight 1 < limit 2) — no queue.
        #expect(await gate.wait(key: key("wan-3"), host: wanHost, link: .wan))
        #expect(await gate.queueDepths() == (visible: 0, prefetch: 0))

        // Free the two held WAN permits so later checks are uncontested.
        await gate.signal(host: wanHost, outcome: .success)
        await gate.signal(host: wanHost, outcome: .success)

        // --- Transport failure shrinks a wide LAN host ---
        await fillPermits(gate, host: lanHost)  // inFlight 3, limit 3
        // One transport failure: window 3.0 → 1.5 (limit 1). Free the remaining two with more
        // transport failures so the window stays at the floor of 1 (a success would grow it).
        await gate.signal(host: lanHost, outcome: .transportFailure)
        await gate.signal(host: lanHost, outcome: .transportFailure)
        await gate.signal(host: lanHost, outcome: .transportFailure)

        // Effective concurrent limit is now 1: first wait admits, second queues.
        #expect(await gate.wait(key: key("lan-a"), host: lanHost, link: .lan))
        let lanQueued = Task {
            await gate.wait(key: key("lan-b"), host: lanHost, link: .lan)
        }
        await waitUntil("shrunk LAN host should serialize the second waiter") {
            await gate.queueDepths().prefetch == 1
        }

        // --- A second, different host is unaffected by lanHost's shrink ---
        // Fresh WAN host still seeds at 1 and admits its first wait immediately even while
        // lanHost has a waiter queued — two hosts don't share one global budget.
        #expect(await gate.wait(key: key("other-1"), host: "other-nas", link: .wan))
        #expect(await gate.queueDepths().prefetch == 1)  // lan-b still queued on lanHost

        // Drain so no waiter leaks a suspended continuation past the test.
        await gate.signal(host: lanHost, outcome: .success)
        #expect(await lanQueued.value)
        await gate.signal(host: lanHost, outcome: .success)
        await gate.signal(host: "other-nas", outcome: .success)
    }

    /// Per-host windows deliberately don't share a budget, which is exactly why a GLOBAL bound is
    /// needed on top: two healthy hosts at their own ceilings would otherwise stack twice the
    /// concurrent bridges + demuxes, and generations are never cancelled so every one of them runs
    /// to the end. The bound is a safety net, not the operating point — AIMD stays in charge below it.
    @Test("a global in-flight ceiling caps two healthy hosts, and drains back open")
    func globalInFlightCeiling() async {
        let gate = ThumbnailGate()
        let hostA = "nas-a"
        let hostB = "nas-b"

        // Grow both hosts to the per-host ceiling of 4 (LAN seeds 3; 3 successes earn the 4th slot).
        for host in [hostA, hostB] {
            for _ in 0..<3 {
                #expect(await gate.wait(key: key("warm-\(host)"), host: host, link: .lan))
                await gate.signal(host: host, outcome: .success)
            }
        }

        // 4 + 4 = 8 permits if only the per-host windows applied; the global bound stops at 6.
        for i in 0..<4 { #expect(await gate.wait(key: key("a-\(i)"), host: hostA, link: .lan)) }
        for i in 0..<2 { #expect(await gate.wait(key: key("b-\(i)"), host: hostB, link: .lan)) }

        // hostB's own window has a free slot (2 of 4 used) — only the global bound blocks this.
        let blocked = Task { await gate.wait(key: key("b-2"), host: hostB, link: .lan) }
        await waitUntil("the global ceiling should queue a per-host-admissible waiter") {
            await gate.queueDepths().prefetch == 1
        }

        // Releasing one permit anywhere drops total in-flight below the bound and admits it.
        await gate.signal(host: hostA, outcome: .success)
        #expect(await blocked.value)

        // Drain so no waiter leaks a suspended continuation past the test.
        for _ in 0..<3 { await gate.signal(host: hostA, outcome: .success) }
        for _ in 0..<3 { await gate.signal(host: hostB, outcome: .success) }
    }

    /// A shrink can't retract permits already handed out, so the window legitimately sits BELOW
    /// in-flight for a while. Nothing may be admitted during that overhang — otherwise a host that
    /// just proved it can't keep up would be handed a fresh generation the moment any older one
    /// finished, and the multiplicative decrease would never actually reduce concurrency.
    @Test("a shrink below in-flight admits nothing until the excess drains")
    func shrinkHoldsAdmissionUntilDrained() async {
        let gate = ThumbnailGate()
        await fillPermits(gate)  // inFlight 3, limit 3

        // One transport failure: window 3.0 → 1.5 (limit 1), while 2 permits are still held.
        await gate.signal(host: testHost, outcome: .transportFailure)

        let queued = Task { await gate.wait(key: key("after-shrink"), host: testHost, link: .lan) }
        await waitUntil("the waiter should queue behind the overhang") {
            await gate.queueDepths().prefetch == 1
        }

        // Down to 1 in flight — still AT the limit, so still nothing admitted.
        await gate.signal(host: testHost, outcome: .transportFailure)
        #expect(await gate.queueDepths().prefetch == 1, "in-flight is still at the shrunk limit")

        // The last held permit drains: now there is room, and the waiter finally gets one.
        await gate.signal(host: testHost, outcome: .transportFailure)
        #expect(await queued.value)
        await gate.signal(host: testHost, outcome: .success)
    }

    /// The pool re-classes a host when the link changes underneath it (a VPN switched on mid-scroll).
    /// A window that grew wide on LAN must not stay wide over the WAN it is now on — AIMD would only
    /// claw it back one wasted multi-MB download at a time.
    @Test("a link-class flip re-seeds the host's window")
    func linkClassFlipReseeds() async {
        let gate = ThumbnailGate()
        await growToLANCeiling(gate)

        // Now the pool says WAN: the window re-seeds to 1, so the second wait queues.
        #expect(await gate.wait(key: key("wan-1"), host: testHost, link: .wan))
        let queued = Task { await gate.wait(key: key("wan-2"), host: testHost, link: .wan) }
        await waitUntil("a re-seeded WAN window should serialize") {
            await gate.queueDepths().prefetch == 1
        }

        await gate.signal(host: testHost, outcome: .success)
        #expect(await queued.value)
        await gate.signal(host: testHost, outcome: .success)
    }

    /// The other half of the re-seed rule: a nil class means "the pool hasn't measured this host",
    /// not "the host changed". Treating it as a change would throw away everything the window
    /// learned every time a generation happened to run before classification landed.
    @Test("an unclassified link is not a class change and keeps the grown window")
    func nilLinkKeepsTheWindow() async {
        let gate = ThumbnailGate()
        await growToLANCeiling(gate)

        // Four concurrent waits with NO class still admit — the LAN-grown window survived.
        for i in 0..<4 {
            #expect(await gate.wait(key: key("unclassified-\(i)"), host: testHost, link: nil))
        }
        #expect(await gate.queueDepths() == (visible: 0, prefetch: 0))

        for _ in 0..<4 { await gate.signal(host: testHost, outcome: .success) }
    }

    /// The other half of the re-seed rule, from the completion side. A generation bakes its link
    /// class when it STARTS, so a long LAN grab finishing after the pool re-classed the host carries
    /// a class that is already history. `signal` therefore takes no class at all: only a fresh
    /// arrival (`wait`) may seed. Before that, the stale class re-seeded the window back to LAN's 3
    /// and undid the narrowing the WAN arrival had just applied.
    @Test("a completing generation cannot re-seed the window its link class has moved on from")
    func staleCompletionNeverReseeds() async {
        let gate = ThumbnailGate()
        await growToLANCeiling(gate)  // window 4, nothing held

        // A LAN-era generation is in flight …
        #expect(await gate.wait(key: key("lan-inflight"), host: testHost, link: .lan))

        // … when a VPN comes up: the next arrival re-seeds the window to 1, so it queues behind
        // the generation still holding the only permit.
        let wan1 = Task { await gate.wait(key: key("wan-1"), host: testHost, link: .wan) }
        await waitUntil("the re-seeded WAN window should serialize the new arrival") {
            await gate.queueDepths().prefetch == 1
        }

        // The old generation finishes. It carries no class any more, so it can only release its
        // permit — the window stays the WAN 1 the arrival seeded, never back to the LAN 3.
        await gate.signal(host: testHost, outcome: .inconclusive)
        #expect(await wan1.value)

        let wan2 = Task { await gate.wait(key: key("wan-2"), host: testHost, link: .wan) }
        await waitUntil("the window must still be 1, not the restored LAN width") {
            await gate.queueDepths().prefetch == 1
        }

        await gate.signal(host: testHost, outcome: .success)
        #expect(await wan2.value)
        await gate.signal(host: testHost, outcome: .success)
    }

    /// Grows `testHost`'s window from the LAN seed of 3 to the per-host ceiling of 4, leaving no
    /// permit held.
    private func growToLANCeiling(_ gate: ThumbnailGate) async {
        for _ in 0..<3 {
            #expect(await gate.wait(key: key("warm"), host: testHost, link: .lan))
            await gate.signal(host: testHost, outcome: .success)
        }
    }

    /// `.inconclusive` is the exit for generations that never moved a byte (a cache hit found after
    /// the playback hold, a lost Keychain slot, a local bind failure). They must release the permit —
    /// otherwise the host wedges — without growing the window on evidence they never gathered.
    @Test("an inconclusive outcome releases the permit but leaves the window where it was")
    func inconclusiveReleasesWithoutMovingTheWindow() async {
        let gate = ThumbnailGate()
        let wanHost = "wan-nas"

        // WAN seeds at 1. A `.success` here would grow it to 2 and admit a second waiter.
        #expect(await gate.wait(key: key("wan-1"), host: wanHost, link: .wan))
        await gate.signal(host: wanHost, outcome: .inconclusive)

        // The permit came back (this admits), but the window is still 1 (the next one queues).
        #expect(await gate.wait(key: key("wan-2"), host: wanHost, link: .wan))
        let queued = Task { await gate.wait(key: key("wan-3"), host: wanHost, link: .wan) }
        await waitUntil("the window must not have grown") {
            await gate.queueDepths().prefetch == 1
        }

        await gate.signal(host: wanHost, outcome: .success)
        #expect(await queued.value)
        await gate.signal(host: wanHost, outcome: .success)
    }
}
