import Foundation
import Testing
import ParallaxFileBrowse
@testable import Parallax

/// `ThumbnailGate` scheduling policy: constant 3 permits with the WAN cap, the gate-owned
/// visible/prefetch banding (counted `promote`/`demote` claims decide the band at enqueue —
/// callers declare nothing), and the bounded prefetch backlog. These are the invariants behind
/// the "visible tiles are served before scrolled-past backlog" behavior, exercised directly on
/// the gate — no SMB, no provider. The time limit is the anti-hang net for the suite's awaits on
/// gate continuations: a regression that never resumes a waiter fails its own test instead of
/// wedging the run (it sits above the CI-scaled `waitUntil` ceiling, which stays the first
/// reporter).
@Suite("ThumbnailGate", .timeLimit(.minutes(3)))
struct ThumbnailGateTests {

    private func key(_ path: String) -> SMBThumbnailKey {
        SMBTestFixtures.thumbnailKey(path: path)
    }

    /// Order-of-admission recorder shared by the queued waiters.
    private actor Admissions {
        var order: [String] = []
        func record(_ name: String) { order.append(name) }
    }

    /// Fills all 3 permits with LAN holders so every subsequent `wait` queues.
    private func fillPermits(_ gate: ThumbnailGate) async {
        for i in 0..<3 {
            #expect(await gate.wait(key: key("holder-\(i)"), link: .lan))
        }
    }

    @Test("three LAN permits admit immediately; the fourth queues")
    func permitCapacity() async {
        let gate = ThumbnailGate()
        await fillPermits(gate)

        let queued = Task { await gate.wait(key: key("fourth"), link: .lan) }
        await waitUntil("fourth wait should queue") {
            await gate.queueDepths().prefetch == 1
        }

        await gate.signal(link: .lan)
        #expect(await queued.value)
    }

    @Test("a promoted key is admitted before earlier-queued prefetch waiters")
    func visibleBandOutranksPrefetch() async {
        let gate = ThumbnailGate()
        let admissions = Admissions()
        await fillPermits(gate)

        // Prefetch waiter first (FIFO would serve it first) …
        let warm = Task {
            _ = await gate.wait(key: key("warm"), link: .lan)
            await admissions.record("warm")
        }
        await waitUntil("prefetch waiter should queue") { await gate.queueDepths().prefetch == 1 }

        // … then a visibly demanded key, enqueued AFTER but admitted FIRST.
        await gate.promote(key("seen"))
        let seen = Task {
            _ = await gate.wait(key: key("seen"), link: .lan)
            await admissions.record("seen")
        }
        await waitUntil("visible waiter should queue") { await gate.queueDepths().visible == 1 }

        await gate.signal(link: .lan)
        await waitUntil("visible waiter should admit first") { await admissions.order == ["seen"] }
        await gate.signal(link: .lan)
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
            _ = await gate.wait(key: key("gone"), link: .lan)
            await admissions.record("gone")
        }
        await waitUntil("visible waiter should queue") { await gate.queueDepths().visible == 1 }

        // … an unrelated prefetch waiter behind it …
        let warm = Task {
            _ = await gate.wait(key: key("warm"), link: .lan)
            await admissions.record("warm")
        }
        await waitUntil("prefetch waiter should queue") { await gate.queueDepths().prefetch == 1 }

        // … then the scroll-off: the visible waiter joins the prefetch TAIL.
        await gate.demote(key("gone"))
        await waitUntil("demoted waiter should move bands") {
            await gate.queueDepths() == (visible: 0, prefetch: 2)
        }

        await gate.signal(link: .lan)
        await waitUntil("older prefetch admits first") { await admissions.order == ["warm"] }
        await gate.signal(link: .lan)
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

        let queued = Task { await gate.wait(key: key("k"), link: .lan) }
        await waitUntil("waiter should land in the band the record says") {
            let depths = await gate.queueDepths()
            return demandWithdrawn ? depths == (0, 1) : depths == (1, 0)
        }
        await gate.signal(link: .lan)
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

        let queued = Task { await gate.wait(key: key("k"), link: .lan) }
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

        await gate.signal(link: .lan)
        #expect(await queued.value)
    }

    @Test("the prefetch backlog evicts its oldest waiter as abandoned beyond the cap")
    func prefetchBacklogEviction() async {
        let gate = ThumbnailGate()
        await fillPermits(gate)

        // First in — the one the over-cap enqueue must evict (resumed `false`, no permit).
        let oldest = Task { await gate.wait(key: key("prefetch-0"), link: .lan) }
        await waitUntil("oldest should queue") { await gate.queueDepths().prefetch == 1 }

        // Fill to the cap exactly (24 queued including `oldest`) — no eviction yet.
        var later: [Task<Bool, Never>] = []
        for i in 1...23 {
            later.append(Task { await gate.wait(key: key("prefetch-\(i)"), link: .lan) })
            await waitUntil("waiter \(i) should queue") {
                await gate.queueDepths().prefetch == i + 1
            }
        }

        // The 25th enqueue crosses the cap: the oldest is resumed as ABANDONED, depth stays 24.
        later.append(Task { await gate.wait(key: key("prefetch-24"), link: .lan) })
        #expect(await oldest.value == false)
        await waitUntil("depth should settle at the cap") { await gate.queueDepths().prefetch == 24 }

        // Drain so no waiter leaks a suspended continuation past the test.
        for _ in 0..<24 { await gate.signal(link: .lan) }
        for task in later { #expect(await task.value) }
    }

    @Test("WAN admission is serialized to one permit; LAN passes the blocked WAN waiter")
    func wanSerialization() async {
        let gate = ThumbnailGate()
        let admissions = Admissions()

        #expect(await gate.wait(key: key("wan-1"), link: .wan))

        // Second WAN generation queues despite 2 free permits …
        let wan2 = Task {
            _ = await gate.wait(key: key("wan-2"), link: .wan)
            await admissions.record("wan-2")
        }
        await waitUntil("second WAN waiter should queue") { await gate.queueDepths().prefetch == 1 }

        // … while LAN work is admitted straight past it.
        #expect(await gate.wait(key: key("lan"), link: .lan))

        await gate.signal(link: .wan)
        await waitUntil("blocked WAN waiter admits once the WAN permit frees") {
            await admissions.order == ["wan-2"]
        }
        _ = await wan2.value
    }
}
