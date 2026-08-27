import Testing
import Foundation
import CoreMedia
#if canImport(MobileVLCKit)
import MobileVLCKit
#else
import TVVLCKit
#endif
import ParallaxPlaybackTestSupport
import ParallaxTestScaling
@testable import ParallaxPlayback

/// Everything the `VLCPlayerControlling` seam bought: the paths that used to be
/// device-verified only because `VLCMediaPlayer` offered nothing to spy on.
///
/// The spy models 3.x's clock honestly — a `time` write is recorded but does not change what
/// the getter returns — which is exactly the condition every assertion here turns on.
/// Waits for the progress poll to produce `condition`. 3.x has no seek-completion or
/// track-selection callback, so the poll IS the engine's only settle signal — and its 500ms
/// tick shares the MainActor with every other suite, which makes a fixed sleep a flake.
@MainActor
private func waitForPoll(
    _ condition: () -> Bool, timeout: Duration = CITimeScale.seconds(5)
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(25))
    }
}

/// `waitForPoll` where expiry is a FAILURE. The "the reassert stood down" tests assert that
/// nothing happened, which is indistinguishable from the poll never having been scheduled —
/// so they first drive a positive control through this, proving the 500 ms tick really ran.
@MainActor
private func requirePoll(
    _ condition: () -> Bool,
    _ what: Comment,
    timeout: Duration = CITimeScale.seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    try await waitForPoll(condition, timeout: timeout)
    #expect(condition(), what, sourceLocation: sourceLocation)
}

/// Drives the progress poll until it has published two distinct clock advances, so a
/// following "nothing else was written" assertion is a real observation and not a silent poll.
/// Returns with the engine playing.
@MainActor
private func tickThePollTwice(_ engine: VLCKitEngine, _ spy: SpyVLCPlayer) async throws {
    await engine.play()
    spy.advanceClock(toMs: 1_000)
    try await requirePoll({ CMTimeGetSeconds(engine.currentTime) == 1 }, "the poll never ticked")
    spy.advanceClock(toMs: 2_000)
    try await requirePoll({ CMTimeGetSeconds(engine.currentTime) == 2 }, "the poll ticked only once")
}

@Suite("VLCKitEngine — the client-facing display clock")
@MainActor
struct VLCKitDisplayClockTests {

    private func engine(_ spy: SpyVLCPlayer) -> VLCKitEngine { VLCKitEngine(control: spy) }

    /// The D1 defect in its cheapest arrangement. libvlc keeps reporting the PRE-seek clock
    /// for seconds after a `setTime` — on wmv/SMB for the whole 10-poll hold — so a client
    /// renderer reading `player.time` draws the old timeline under a picture that has already
    /// moved, then snaps. `currentTime` must report what the engine considers current.
    @Test("currentTime reports the seek target while the player's own clock is still pre-seek")
    func currentTimeFollowsTheSeekNotTheStaleClock() async throws {
        let spy = SpyVLCPlayer()
        spy.advanceClock(toMs: 10_000)
        let engine = engine(spy)
        try await engine.load(.fixture())

        await engine.seek(to: CMTime(seconds: 75, preferredTimescale: 1_000))

        #expect(spy.seekWritesMs == [75_000])
        #expect(spy.time.intValue == 10_000)   // the stale read the old currentTime shipped
        #expect(CMTimeGetSeconds(engine.currentTime) == 75)
        await engine.teardown()
    }

    /// The resume seek has not been applied to the input yet, so neither the raw clock (still
    /// pre-seek) nor the pending offset (not on screen yet) describes the picture. A renderer
    /// is better off drawing nothing than starting the subtitles at 0:00 under a frame at 42:00.
    @Test("currentTime is invalid for the whole resume-seek window")
    func currentTimeIsInvalidWhileAResumeIsPending() async throws {
        let spy = SpyVLCPlayer()
        spy.stubbedIsSeekable = false   // hold the resume seek in its readiness window
        spy.advanceClock(toMs: 500)
        let engine = engine(spy)

        try await engine.load(.fixture(startTime: CMTime(seconds: 90, preferredTimescale: 1_000)))
        #expect(engine.currentTime == .invalid)

        // The scrubber beat still carries the resume offset (`heldPositionMs`); the client
        // clock deliberately does not follow it there.
        await engine.pause()
        #expect(engine.currentTime == .invalid)
        await engine.teardown()
    }

    /// The other side of the hold: once libvlc republishes and the poll lets go, the client
    /// clock must track the real thing again rather than staying pinned to the target.
    @Test("once the seek hold settles the display clock tracks the player again")
    func displayClockTracksThePlayerAfterTheHoldSettles() async throws {
        let spy = SpyVLCPlayer()
        let engine = engine(spy)
        try await engine.load(.fixture())
        await engine.play()
        await engine.seek(to: CMTime(seconds: 60, preferredTimescale: 1_000))

        spy.advanceClock(toMs: 60_000)      // libvlc's time-changed event lands
        try await waitForPoll { CMTimeGetSeconds(engine.currentTime) == 60 }
        #expect(CMTimeGetSeconds(engine.currentTime) == 60)

        spy.advanceClock(toMs: 61_000)
        try await waitForPoll { CMTimeGetSeconds(engine.currentTime) == 61 }
        #expect(CMTimeGetSeconds(engine.currentTime) == 61)
        await engine.teardown()
    }
}

@Suite("VLCKitEngine — media options")
struct VLCKitMediaOptionTests {

    /// D3: the app draws every text subtitle itself, so libvlc's SPU renderer has to be blind
    /// for the whole input. The 500ms poll re-assert stays as the backstop, but it cannot
    /// cover the window between `load()` and the app's first `setSubtitleTrack(nil)`.
    @Test("`:no-spu` rides exactly the assets that render their own subtitles",
          arguments: [true, false])
    func noSpuTracksTheAssetIntent(disabled: Bool) {
        let options = VLCKitEngine.mediaOptions(for: .fixture(engineSubtitlesDisabled: disabled))
        #expect(options.contains(":no-spu") == disabled)
    }

    /// D2: two renderers, two option *semantics*. `ssa-fontsdir` is a directory libass scans;
    /// `freetype-font` is a font FAMILY NAME. Handing the latter a path is a silent no-op that
    /// falls back to the module's hardcoded Helvetica Neue — which is why embedded CJK SRT
    /// rendered as tofu while the ASS path was fine.
    @Test("the fonts directory and the font family go to their own renderers")
    func fontOptionsMatchTheirRenderers() {
        let options = VLCKitEngine.mediaOptions(for: .fixture(
            subtitleFontsDirectory: URL(fileURLWithPath: "/tmp/parallax-fonts"),
            subtitleFontFamily: "PingFang SC"
        ))
        #expect(options.contains(":ssa-fontsdir=/tmp/parallax-fonts"))
        #expect(options.contains(":freetype-font=PingFang SC"))
    }

    /// Neither option is invented when the app has nothing to offer: an empty `freetype-font`
    /// would match no family at all.
    @Test("no font options at all when the asset carries neither")
    func fontOptionsAreOmittedWhenAbsent() {
        let options = VLCKitEngine.mediaOptions(for: .fixture())
        #expect(options.contains(where: { $0.hasPrefix(":ssa-fontsdir") }) == false)
        #expect(options.contains(where: { $0.hasPrefix(":freetype-font=") }) == false)
    }

    /// Caller-supplied options are applied LAST so they can override the engine's defaults.
    @Test("caller options are applied after the engine's own")
    func callerOptionsComeLast() {
        let asset = PlayableAsset(
            url: URL(fileURLWithPath: "/dev/null"), headers: nil, hints: .fixture(),
            startTime: nil, vlcOptions: [":smb-user=someone"]
        )
        #expect(VLCKitEngine.mediaOptions(for: asset).last == ":smb-user=someone")
    }
}

@Suite("VLCKitEngine — subtitle track and delay")
@MainActor
struct VLCKitSubtitleControlTests {

    private func spyOfferingOneTrack() -> SpyVLCPlayer {
        let spy = SpyVLCPlayer()
        spy.stubbedSubtitleTrackIndexes = [NSNumber(value: 3)]
        spy.stubbedSubtitleTrackNames = ["English"]
        return spy
    }

    /// D3's software half. With `:no-spu` set the engine's SPU is blind anyway, so honouring a
    /// selection would only desynchronize the latch from what is on screen — and a menu pick
    /// that silently does nothing is better than two subtitle streams at slightly different times.
    @Test("setSubtitleTrack is refused for an asset that renders its own subtitles")
    func setSubtitleTrackIsRefusedWhenTheClientDraws() async throws {
        let spy = spyOfferingOneTrack()
        let engine = VLCKitEngine(control: spy)
        try await engine.load(.fixture(engineSubtitlesDisabled: true))

        await engine.setSubtitleTrack(VLCKitEngine.buildSubtitleTrack(id: "3", name: "English", language: nil))

        #expect(spy.subtitleTrackWrites.isEmpty)
        #expect(spy.currentVideoSubTitleIndex == -1)
        await engine.teardown()
    }

    /// The control: an ordinary asset still selects normally, so the refusal above is the
    /// asset's intent talking and not a broken selector.
    @Test("setSubtitleTrack still selects for an ordinary asset")
    func setSubtitleTrackSelectsNormally() async throws {
        let spy = spyOfferingOneTrack()
        let engine = VLCKitEngine(control: spy)
        try await engine.load(.fixture())

        await engine.setSubtitleTrack(VLCKitEngine.buildSubtitleTrack(id: "3", name: "English", language: nil))

        #expect(spy.currentVideoSubTitleIndex == 3)
        await engine.teardown()
    }

    /// `currentVideoSubTitleDelay` is scoped to the ACTIVE INPUT, and libvlc drops a write
    /// issued before that input is up. The engine re-asserts until it sticks — same
    /// command-drop family as the rate.
    @Test("the requested subtitle delay is re-asserted onto the input it was set against")
    func subtitleDelayIsReassertedOntoItsOwnInput() async throws {
        let spy = SpyVLCPlayer()
        let engine = VLCKitEngine(control: spy)
        try await engine.load(.fixture())
        await engine.setSubtitleDelay(milliseconds: -250)
        #expect(spy.currentVideoSubTitleDelay == -250_000)

        spy.currentVideoSubTitleDelay = 0    // libvlc dropped it
        await engine.play()

        try await waitForPoll { spy.currentVideoSubTitleDelay == -250_000 }
        #expect(spy.currentVideoSubTitleDelay == -250_000)
        #expect(await engine.debugSnapshot().subtitleDelayMs == -250)
        await engine.teardown()
    }

    /// The delay belongs to the MEDIA it was tuned against. A reused engine loading a
    /// DIFFERENT item (the next episode) inherited the previous one's nudge, so an episode
    /// with correctly muxed subtitles started 2s out with nothing on screen saying why.
    /// The app owns the per-item intent and re-applies it after a same-item reload.
    @Test("load() drops the delay with the media it belonged to")
    func loadResetsTheSubtitleDelay() async throws {
        let spy = SpyVLCPlayer()
        let engine = VLCKitEngine(control: spy)
        try await engine.load(.fixture())
        await engine.setSubtitleDelay(milliseconds: -2000)

        try await engine.load(.fixture(url: URL(string: "file:///next-episode.mkv")!))
        spy.currentVideoSubTitleDelay = 0    // the fresh input starts the variable over

        #expect(await engine.debugSnapshot().subtitleDelayMs == 0)
        // The positive control: two observed poll ticks, so "no delay was re-asserted" is an
        // observation rather than a poll that never got scheduled.
        try await tickThePollTwice(engine, spy)
        #expect(spy.subtitleDelayWrites.count == 2)   // only the two writes above
        #expect(spy.currentVideoSubTitleDelay == 0)
        await engine.teardown()
    }

    /// A `:no-spu` asset has no subtitle input variable to converge on, so the readback can
    /// never match and the write was re-issued on every 500 ms tick, forever, for nothing.
    @Test("the delay reassert stands down on an asset that renders its own subtitles")
    func subtitleDelayReassertSkipsBlindedAssets() async throws {
        let spy = SpyVLCPlayer()
        let engine = VLCKitEngine(control: spy)
        try await engine.load(.fixture(engineSubtitlesDisabled: true))
        await engine.setSubtitleDelay(milliseconds: -250)   // the one direct write
        let writesAfterSet = spy.subtitleDelayWrites.count

        spy.currentVideoSubTitleDelay = 0   // a readback the reassert could never satisfy
        // The positive control: the poll must be proven to have run, or "it stood down" and
        // "it never ticked" are the same green.
        try await tickThePollTwice(engine, spy)

        #expect(spy.subtitleDelayWrites.count == writesAfterSet + 1)   // only the manual reset
        await engine.teardown()
    }
}

@Suite("VLCKitEngine — teardown")
@MainActor
struct VLCKitTeardownTests {

    /// D5: 3.x's `stop()` is synchronous and winds the input down on the CALLING thread,
    /// which on SMB is routinely parked mid-network-read for seconds. Inline on the MainActor
    /// that wait lands on the thread drawing the dismissal — `endAudio()` documents exactly
    /// this and detaches; `teardown()` never got the same treatment, and it is the path a load
    /// failure, a reactive engine swap and a `.failed` retry all take.
    @Test("teardown's stop never runs on the MainActor")
    func teardownStopsOffTheMainActor() async {
        let spy = SpyVLCPlayer()
        let engine = VLCKitEngine(control: spy)

        await engine.teardown()

        #expect(spy.stopCalls == 1)
        #expect(spy.stopCalledOnMainThread == false)
        #expect(engine.pendingStopTask == nil)   // joined, not left in flight
    }

    /// The other half of the detached stop. Releasing the MainActor for the wind-down left
    /// every non-transport command live, and the outgoing HUD stays hit-testable through the
    /// dismiss animation — so a scrub commit landing there wrote `player.time` on main while
    /// the stop drove the same non-Sendable player elsewhere (`Assertion failed: (p_md)`).
    @Test("no command reaches the player while a detached stop is in flight")
    func playerWritesAreInertWhileWindingDown() async throws {
        let spy = SpyVLCPlayer()
        // A real audio inventory, so `setAudioTrack`'s own id validation can't be what
        // swallows the write below.
        spy.stubbedAudioTrackIndexes = [NSNumber(value: 1)]
        spy.stubbedAudioTrackNames = ["English"]
        spy.holdStops()
        let engine = VLCKitEngine(control: spy)
        try await engine.load(.fixture())
        let seekWritesBeforeExit = spy.seekWritesMs.count
        let rateWritesBeforeExit = spy.rateWrites.count

        await engine.endAudio()          // the stop is now parked in the spy's gate
        #expect(engine.isWindingDown)

        await engine.seek(to: CMTime(seconds: 30, preferredTimescale: 1_000))
        await engine.setRate(2)
        await engine.setSubtitleDelay(milliseconds: -500)
        await engine.setSubtitleTrack(nil)
        await engine.setAudioTrack(VLCKitEngine.buildAudioTrack(id: "1", name: "English", language: nil))
        await engine.play()
        await engine.pause()

        #expect(spy.seekWritesMs.count == seekWritesBeforeExit)
        #expect(spy.rateWrites.count == rateWritesBeforeExit)
        #expect(spy.subtitleDelayWrites.isEmpty)
        #expect(spy.subtitleTrackWrites.isEmpty)
        #expect(spy.audioTrackWrites.isEmpty)
        #expect(spy.playCalls == 0)
        #expect(spy.pauseCalls == 0)

        spy.stopHolding()
        await engine.teardown()
    }

    /// The latch belongs to the session, not the engine: the transcode reload reuses one
    /// engine, so `load()` has to hand the player back.
    @Test("load() lowers the wind-down latch so a reused engine still takes commands")
    func loadLowersTheWindDownLatch() async throws {
        let spy = SpyVLCPlayer()
        let engine = VLCKitEngine(control: spy)
        try await engine.load(.fixture())
        await engine.endAudio()

        try await engine.load(.fixture(url: URL(string: "file:///next-episode.mkv")!))
        #expect(engine.isWindingDown == false)

        await engine.seek(to: CMTime(seconds: 30, preferredTimescale: 1_000))
        #expect(spy.seekWritesMs.contains(30_000))
        await engine.teardown()
    }

    /// The join used to clear `pendingStopTask` unconditionally after its await, so a stop
    /// assigned DURING the suspension (a dismissal fence firing while teardown waits on
    /// `endAudio()`'s stop) was dropped un-awaited — and the caller walked into the
    /// drawable/delegate/stop sequence with it still running.
    @Test("a stop assigned while the join is suspended is not dropped")
    func awaitPendingStopKeepsALaterStop() async throws {
        let spy = SpyVLCPlayer()
        spy.holdStops()
        let engine = VLCKitEngine(control: spy)

        engine.scheduleDetachedStop()                        // stop A, parked in the gate
        let joiner = Task { await engine.awaitPendingStop() }
        try await Task.sleep(for: .milliseconds(50))         // let the join reach its await
        engine.scheduleDetachedStop()                        // stop B, assigned mid-suspension
        spy.releaseHeldStop()                                // A completes; B stays parked

        try await waitForPoll({ spy.stopCalls == 1 })
        // The bug nils the reference the moment A returns; the fix keeps joining B.
        try await waitForPoll({ engine.pendingStopTask == nil }, timeout: .milliseconds(500))
        #expect(engine.pendingStopTask != nil)

        spy.stopHolding()
        await joiner.value
        #expect(spy.stopCalls == 2)
        #expect(engine.pendingStopTask == nil)
        await engine.teardown()
    }
}

@Suite("VLCKitEngine — events configuration")
@MainActor
struct VLCKitEventsConfigurationTests {

    /// `VLCLibrary.sharedEventsConfiguration` has to be installed BEFORE the first
    /// `VLCMediaPlayer`/`VLCLibrary` exists or delegate callbacks arrive off the main queue
    /// and every `MainActor.assumeIsolated` hop in the engine traps. Touching the one-time
    /// `static let` from the designated init was too late — a convenience init's arguments
    /// (including `VLCMediaPlayer()`) are evaluated before the callee body runs. Every player
    /// now comes out of `makePlayer`, which touches it first.
    @Test("the player factory installs the legacy events configuration")
    func makePlayerInstallsTheEventsConfiguration() {
        _ = VLCKitEngine.makePlayer(libraryOptions: nil)
        #expect(VLCLibrary.sharedEventsConfiguration is VLCEventsLegacyConfiguration)
    }

    @Test("constructing an engine leaves the events configuration installed")
    func constructionLeavesTheEventsConfigurationInstalled() async {
        let engine = VLCKitEngine(control: SpyVLCPlayer())
        #expect(VLCLibrary.sharedEventsConfiguration is VLCEventsLegacyConfiguration)
        await engine.teardown()
    }
}
