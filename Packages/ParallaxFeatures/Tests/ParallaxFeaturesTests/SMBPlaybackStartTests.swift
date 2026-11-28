import Foundation
import Synchronization
import CoreMedia
import Testing
import ParallaxCore
@testable import ParallaxFeatures
import ParallaxPlayback
import ParallaxCoreTestSupport
import ParallaxPlaybackTestSupport
import ParallaxSubtitles
@testable import ParallaxJellyfin
@testable import ParallaxCore

/// SMB direct-play entry: `PlayerViewModel.start(smbItem:)` builds a `PlayableAsset`
/// straight from a resolved SMB file, served over the local bridge: no Jellyfin resolve,
/// no DeviceProfile, no playSessionID, no progress reporting.
@Suite("PlayerViewModel SMB start", .timeLimit(.minutes(1)))
@MainActor
struct SMBPlaybackStartTests {

    /// A VM with a resolve closure that MUST NOT run on the SMB path — calling it
    /// fails the test, proving `start(smbItem:)` never touches the Jellyfin resolve.
    private func makeVM(
        reporting: StubPlaybackReporting,
        engine: FakePlaybackEngine,
        audioSession: any AudioSessionControlling = NoopAudioSession(),
        subtitleFetch: @escaping @Sendable (URL) async -> SubtitleFetchOutcome = { _ in .rejected },
        // NOT `SMBResumeStore.shared`: that one reads and writes the real `UserDefaults.standard`
        // domain, so every test here that drives a `.playing` beat was writing live app state.
        smbResumeStore: SMBResumeStore? = nil,
        clock: TestClock = TestClock()
    ) -> PlayerViewModel {
        return PlayerViewModel(
            deviceProfileBuilder: makeTestDeviceProfileBuilder(),
            clock: clock,
            playbackInfo: reporting,
            resolve: { _, _, _, _ in
                Issue.record("SMB playback must not call the Jellyfin resolve")
                throw AppError.playback(.unsupportedFormat(reason: nil))
            },
            engineFactory: { engine },
            audioSession: audioSession,
            nowPlaying: SpyNowPlaying(),
            subtitleFetch: subtitleFetch,
            smbResumeStore: smbResumeStore ?? SMBTestFixtures.inertResumeStore()
        )
    }

    private func smbItem(
        url: String = "http://127.0.0.1:8080/token/Example.mp4",
        title: String = "Example",
        itemID: ItemID = ItemID(rawValue: "smb-test-item"),
        subtitleURLs: [Int: URL] = [:],
        subtitleLabels: [Int: String] = [:]
    ) -> SMBPlaybackItem {
        SMBPlaybackItem(
            itemID: itemID,
            url: URL(string: url)!,
            title: title,
            subtitleURLs: subtitleURLs,
            subtitleLabels: subtitleLabels
        )
    }

    /// Counts resolve-closure invocations so a test can prove `retry()` replays it.
    private actor ResolveAttempts {
        private(set) var count = 0
        func bump() -> Int { count += 1; return count }
    }

    @Test("builds an asset on the item's bridge URL, then loads + plays")
    func startBuildsSMBAssetAndPlays() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine()
        let vm = makeVM(reporting: reporting, engine: engine)

        let item = smbItem()
        await vm.start(smbItem: item)

        #expect(engine.loadedAssets.count == 1)
        let asset = try #require(engine.loadedAssets.first)
        #expect(asset.url == item.url)
        #expect(engine.calls.contains("load"))
        #expect(engine.calls.contains("play"))

        // The session reaches .playing once the engine reports it — proving the beat
        // handler doesn't drop SMB beats just because `resolved == nil`.
        engine.push(.playing(5, duration: .seconds(6000)))
        try await engine.settle()
        #expect(vm.phase == .playing)
        #expect(vm.isPlaying == true)
    }

    @Test("no Jellyfin reporting fires on the SMB path — resolved stays nil end to end")
    func smbPathNeverReports() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine()
        let vm = makeVM(reporting: reporting, engine: engine)

        await vm.start(smbItem: smbItem())

        // Drive a full play → progress → ended lifecycle.
        engine.push(.playing(10, duration: .seconds(6000)))
        engine.push(.playing(20, duration: .seconds(6000)))
        engine.push(.paused(20, duration: .seconds(6000)))
        engine.push(.ended)
        try await engine.settle()

        // resolved == nil is observable through the report contract: a Jellyfin
        // session would have fired start/progress/stopped beats; the SMB session
        // fires NONE (no resolved → no beat to build, no playSessionID to report).
        #expect(await reporting.events.isEmpty)
        #expect(await reporting.pings.isEmpty)
        #expect(await reporting.stoppedEncodings.isEmpty)
    }

    // MARK: - Local resume vs an unknown duration

    /// One position, two verdicts, decided solely by whether the stream knows its length. 5900s of
    /// a 6000s runtime is 98.3%, past the store's completion fraction, so it clears a finished film;
    /// with no length there is no fraction, and the position must survive.
    @Test(
        "the completion-clear rule applies only to a known duration",
        arguments: [
            (false, Double?.some(5_900)),
            (true, Double?.none),
        ]
    )
    func completionClearNeedsAKnownDuration(knownDuration: Bool, expectedResume: Double?) async throws {
        try await SMBTestFixtures.withResumeStore(suite: #function) { store in
            let reporting = StubPlaybackReporting()
            let engine = FakePlaybackEngine()
            let vm = makeVM(reporting: reporting, engine: engine, smbResumeStore: store)
            let id = ItemID(rawValue: "smb-known-duration-\(knownDuration)")

            await vm.start(smbItem: smbItem(itemID: id))
            engine.push(.playing(5_900, duration: knownDuration ? .seconds(6_000) : .indefinite))
            try await engine.settle()

            // stop()'s final save is unthrottled and inline-awaited — deterministic to assert
            // straight after, no throttle-window race.
            await vm.stop()

            let resumed = await store.resumeTime(for: id)
            if let expectedResume {
                #expect(abs(CMTimeGetSeconds(try #require(resumed)) - expectedResume) < 0.001)
            } else {
                #expect(resumed == nil)
            }
        }
    }

    /// The beats come faster than the store should be written, so a playing session persists at
    /// most once per 10 s of the player's clock. The first beat always writes. Saves land in the
    /// order they were spawned, so a wrongly spawned save at 109 would show up in the sequence
    /// ahead of 110.
    @Test("a playing SMB session persists its position at most once every 10 seconds")
    func resumeWritesAreThrottledOnTheClock() async throws {
        let suiteName = "SMBPlaybackStartTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let writes = PositionLog()
        let store = SMBResumeStore(defaults: RecordingDefaults(suiteName: suiteName, log: writes)!)
        let clock = TestClock()
        let engine = FakePlaybackEngine()
        let vm = makeVM(reporting: StubPlaybackReporting(), engine: engine, smbResumeStore: store, clock: clock)
        let id = ItemID(rawValue: "smb-resume-throttle")
        await vm.start(smbItem: smbItem(itemID: id))

        engine.push(.playing(100, duration: .seconds(6_000)))
        try await engine.settle()
        clock.advance(by: .seconds(9))
        engine.push(.playing(109, duration: .seconds(6_000)))
        try await engine.settle()
        clock.advance(by: .seconds(1))
        engine.push(.playing(110, duration: .seconds(6_000)))
        try await engine.settle()

        await waitUntil("the beat 10 s later never wrote its position") { await store.resumeTime(for: id).map(CMTimeGetSeconds) == 110 }
        #expect(writes.positions == [100, 110])
    }

    @Test("a stale throttled save can't outrun .ended's terminal clear")
    func throttledSaveNeverOutrunsEndedClear() async throws {
        try await SMBTestFixtures.withResumeStore(suite: #function) { store in
            let reporting = StubPlaybackReporting()
            let engine = FakePlaybackEngine()
            let vm = makeVM(reporting: reporting, engine: engine, smbResumeStore: store)
            let id = ItemID(rawValue: "smb-save-vs-clear")

            await vm.start(smbItem: smbItem(itemID: id))

            // The throttle window is wide open (first beat), so `.playing` spawns the untracked
            // save `.ended` must now await. Before the fix, the save Task's actor hop could lose
            // a race against `.ended`'s clear() — landing after it and resurrecting this position.
            engine.push(.playing(100, duration: .seconds(6_000)))
            engine.push(.ended)
            try await engine.settle()

            #expect(await store.resumeTime(for: id) == nil)
        }
    }

    // MARK: - start(resolvingSMB:) — resolve under the veil

    @Test("resolving start: the closure's item is loaded + played, no Jellyfin reporting")
    func resolvingStartLoadsResolvedItem() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine()
        let vm = makeVM(reporting: reporting, engine: engine)

        let resolved = smbItem()
        await vm.start(resolvingSMB: { resolved })

        // Same assertions as startBuildsSMBAssetAndPlays: the resolve closure's item
        // is the one the engine loaded + played.
        #expect(engine.loadedAssets.count == 1)
        let asset = try #require(engine.loadedAssets.first)
        #expect(asset.url == resolved.url)
        #expect(engine.calls.contains("load"))
        #expect(engine.calls.contains("play"))

        engine.push(.playing(5, duration: .seconds(6000)))
        try await engine.settle()
        #expect(vm.phase == .playing)

        // No server in the loop: the resolve-then-delegate path reports nothing.
        #expect(await reporting.events.isEmpty)
        #expect(await reporting.pings.isEmpty)
        #expect(await reporting.stoppedEncodings.isEmpty)
    }

    @Test("resolving start: a resolve that throws an AppError lands on the failure scrim; the engine never loads")
    func resolvingStartSurfacesAppErrorOnFailureScrim() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine()
        let vm = makeVM(reporting: reporting, engine: engine)

        let thrown = AppError.source(.notFound)
        await vm.start(resolvingSMB: { throw thrown })

        guard case .failed(let error) = vm.phase else {
            Issue.record("expected .failed, got \(vm.phase)")
            return
        }
        #expect(error.diagnosticDescription == thrown.diagnosticDescription)
        // Resolution failed before any asset reached the engine.
        #expect(engine.loadedAssets.isEmpty)
        #expect(!engine.calls.contains("load"))
        #expect(await reporting.events.isEmpty)
    }

    @Test("retry() replays the SMB resolve closure — Try again is live on the SMB path")
    func retryReplaysSMBResolve() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine()
        let vm = makeVM(reporting: reporting, engine: engine)

        let attempts = ResolveAttempts()
        let resolved = smbItem()
        let resolve: () async throws -> SMBPlaybackItem = {
            _ = await attempts.bump()
            return resolved
        }

        await vm.start(resolvingSMB: resolve)
        #expect(await attempts.count == 1)

        // retry() sets neither playingItem nor pendingItemID on the SMB path, so before the
        // fix it fell through to a no-op log and the closure was never re-run (dead "Try
        // again"). It must now replay the stored SMB resolve.
        await vm.retry()
        #expect(await attempts.count == 2)
        #expect(engine.calls.contains("load"))
    }

    /// Records how many times the bridge cleanup was invoked.
    private actor CleanupSpy {
        private(set) var count = 0
        func invoke() { count += 1 }
    }

    @Test("resolving start: an exit racing the resolve reaps the bridge cleanup (no orphan)")
    func resolvingStartExitRaceReapsBridge() async throws {
        let reporting = StubPlaybackReporting()
        let engine = FakePlaybackEngine()
        let vm = makeVM(reporting: reporting, engine: engine)

        let spy = CleanupSpy()
        let base = smbItem()
        // The cleanup holds a LIVE bridge the session must reap on exit.
        let resolvedItem = SMBPlaybackItem(
            itemID: base.itemID,
            url: base.url,
            title: base.title,
            cleanup: { await spy.invoke() }
        )

        // The resolve runs stop() to completion mid-flight (the onDisappear backstop landing
        // in the resolve window), THEN returns the item. Before the fix the cleanup was
        // stashed only inside start(smbItem:) — never reached past the exit fence — so the
        // bridge orphaned: stop() ran with smbCleanup still nil and never runs again.
        await vm.start(resolvingSMB: {
            await vm.stop()
            return resolvedItem
        })

        // The exit fence bailed before start(smbItem:), so the engine never loaded — but the
        // stashed cleanup was reaped exactly once by the CancellationError branch.
        #expect(!engine.calls.contains("load"))
        #expect(await spy.count == 1)
    }
}

private final class PositionLog: Sendable {
    private let storage = Mutex<[Double]>([])
    var positions: [Double] { storage.withLock { $0 } }
    func append(_ new: [Double]) { storage.withLock { $0.append(contentsOf: new) } }
}

/// A `UserDefaults` that logs every position the resume store writes through it, in order.
private final class RecordingDefaults: UserDefaults, @unchecked Sendable {
    private let log: PositionLog

    init?(suiteName: String, log: PositionLog) {
        self.log = log
        super.init(suiteName: suiteName)
    }

    override func set(_ value: Any?, forKey key: String) {
        if let entries = value as? [String: [String: Double]] {
            log.append(entries.values.compactMap { $0["pos"] })
        }
        super.set(value, forKey: key)
    }
}
