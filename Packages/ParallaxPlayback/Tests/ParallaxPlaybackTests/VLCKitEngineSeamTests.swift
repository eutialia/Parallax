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
/// Drives the progress poll until it has published two distinct clock advances, so a
/// following "nothing else was written" assertion is a real observation and not a silent poll.
/// Returns with the engine playing.
@MainActor
private func tickThePollTwice(_ engine: VLCKitEngine, _ spy: SpyVLCPlayer) async throws {
    await engine.play()
    spy.advanceClock(toMs: 1_000)
    try await requireEventually({ CMTimeGetSeconds(engine.currentTime) == 1 }, "the poll never ticked")
    spy.advanceClock(toMs: 2_000)
    try await requireEventually({ CMTimeGetSeconds(engine.currentTime) == 2 }, "the poll ticked only once")
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
        try await pollUntil { CMTimeGetSeconds(engine.currentTime) == 60 }
        #expect(CMTimeGetSeconds(engine.currentTime) == 60)

        spy.advanceClock(toMs: 61_000)
        try await pollUntil { CMTimeGetSeconds(engine.currentTime) == 61 }
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

    /// D2 and its real cause. `ssa-fontsdir` is read by libvlc's libass DECODER
    /// (`var_InheritString(p_dec, …)`), whose inheritance chain runs through the input item —
    /// so a media option reaches it. The freetype text renderer is built by the video output
    /// (`SpuRenderCreateAndLoadText`), which inherits from the libvlc INSTANCE and never sees
    /// an input's variables: every `:freetype-*` media option was a silent no-op that left the
    /// module on its built-in "Helvetica Neue" and rendered CJK as tofu.
    @Test("the fonts directory rides the media, and nothing freetype does")
    func fontsDirectoryIsTheOnlyMediaScopedFontOption() {
        let options = VLCKitEngine.mediaOptions(for: .fixture(
            subtitleFontsDirectory: URL(fileURLWithPath: "/tmp/parallax-fonts"),
            subtitleFontFamily: "PingFang SC",
            subtitleTextStyle: EngineSubtitleTextStyle(style: .standard, relativeFontSize: 20)
        ))
        #expect(options.contains(":ssa-fontsdir=/tmp/parallax-fonts"))
        #expect(options.contains(where: { $0.contains("freetype") }) == false)
    }

    /// No directory to name, nothing to say.
    @Test("no fonts directory option when the asset carries none")
    func fontsDirectoryIsOmittedWhenAbsent() {
        let options = VLCKitEngine.mediaOptions(for: .fixture())
        #expect(options.contains(where: { $0.hasPrefix(":ssa-fontsdir") }) == false)
        #expect(options.contains(where: { $0.contains("freetype") }) == false)
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

@Suite("VLCKitEngine — library (instance) options")
struct VLCKitLibraryOptionTests {

    /// The fix. The freetype renderer belongs to the video output, so its whole option set has
    /// to arrive as libvlc instance arguments — `--`, not `:`. `.opaqueBox` is the other half
    /// of the user's border choice: box on, ring and shadow off.
    @Test("the font family and the style become the `--freetype-*` argument set",
          arguments: [SubtitleBackground.outlineShadow, .opaqueBox])
    func freetypeArgumentsCarryTheAssetStyle(background: SubtitleBackground) {
        let boxed = background == .opaqueBox
        let style = SubtitleStyle.standard.with { $0.background = background }
        let options = VLCKitEngine.libraryOptions(for: .fixture(
            subtitleFontFamily: "Noto Sans CJK SC",
            subtitleTextStyle: EngineSubtitleTextStyle(style: style, relativeFontSize: 20)
        ))

        #expect(options == [
            "--freetype-font=Noto Sans CJK SC",
            // em = output height / 20 — the divisor the app computed from its own cue size.
            "--freetype-rel-fontsize=20",
            // 0.92 white, fully opaque.
            "--freetype-color=15461355",     // 0xEBEBEB
            "--freetype-opacity=255",
            "--freetype-outline-color=0",
            // The ring is 6% of the font size (the option is a percent, not one of the
            // None/Thin/Normal/Thick presets its labels suggest); a box turns it off by
            // thickness, which is the module's real off switch — STYLE_OUTLINE is always set.
            "--freetype-outline-opacity=\(boxed ? 0 : 255)",
            "--freetype-outline-thickness=\(boxed ? 0 : 6)",
            // 0.55 × 255 = 140.25, and the 0.04 VERTICAL offset rides the hypotenuse of the
            // module's default −45° shadow angle: 0.04 × √2 = 0.0566.
            "--freetype-shadow-opacity=\(boxed ? 0 : 140)",
            "--freetype-shadow-distance=0.0566",
            "--freetype-background-color=0",
            "--freetype-background-opacity=\(boxed ? 255 : 0)",
        ])
    }

    /// The order is load-bearing: `PlayerViewModel` compares this array against the one the
    /// live engine was built with to decide whether it can reuse the player, so equal inputs
    /// must produce an equal array rather than merely an equal SET.
    @Test("equal assets produce an identical array, element for element")
    func orderingIsStable() {
        func build() -> [String]? {
            VLCKitEngine.libraryOptions(for: .fixture(
                subtitleFontFamily: "Noto Serif CJK JP",
                subtitleTextStyle: EngineSubtitleTextStyle(style: .standard, relativeFontSize: 18),
                vlcLibraryOptions: ["--no-drop-late-frames"]
            ))
        }
        #expect(build() == build())
    }

    /// The pre-existing instance arguments (the timing-repair vout flags) keep their place at
    /// the head — they were always instance-scoped; the subtitle look simply joined them.
    @Test("caller library options pass through, ahead of the subtitle set")
    func callerLibraryOptionsComeFirst() {
        let options = VLCKitEngine.libraryOptions(for: .fixture(
            subtitleFontFamily: "Noto Sans CJK SC",
            vlcLibraryOptions: ["--no-drop-late-frames", "--no-skip-frames"]
        ))
        #expect(options == [
            "--no-drop-late-frames", "--no-skip-frames", "--freetype-font=Noto Sans CJK SC",
        ])
    }

    /// Nothing to say → nil, which is what keeps a bare asset on the shared `VLCLibrary`
    /// instead of minting a private one that differs from it in nothing.
    @Test("nil when the asset carries no family, no style and no library options")
    func nilWhenTheAssetCarriesNothing() {
        #expect(VLCKitEngine.libraryOptions(for: .fixture()) == nil)
    }
}

/// The vendored `VLCLibrary.h` says the framework does not support multiple `VLCLibrary`
/// instances, and `VLCMediaPlayer(options:)` mints one per call. Now that every VLC session
/// carries instance arguments (the subtitle look), that would be one libvlc per playback —
/// so `makePlayer` interns them by option array instead.
@Suite("VLCKitEngine — the private VLCLibrary cache")
@MainActor
struct VLCKitLibraryCacheTests {

    @Test("equal option arrays share one library instance, different ones do not")
    func librariesAreInternedByTheirOptions() {
        let sans = ["--freetype-font=Noto Sans CJK SC"]
        let serif = ["--freetype-font=Noto Serif CJK SC"]

        let first = VLCKitEngine.makePlayer(libraryOptions: sans)
        let second = VLCKitEngine.makePlayer(libraryOptions: sans)
        let other = VLCKitEngine.makePlayer(libraryOptions: serif)

        #expect(first.libraryInstance === second.libraryInstance)
        #expect(first.libraryInstance !== other.libraryInstance)
    }

    /// No options → the shared library, untouched. A private instance for an argument set
    /// identical to the default one would be pure cost.
    @Test("no options keeps the player on the shared library")
    func noOptionsUsesTheSharedLibrary() {
        let player = VLCKitEngine.makePlayer(libraryOptions: nil)
        #expect(player.libraryInstance === VLCLibrary.shared())
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

    /// libvlc demuxes only SELECTED streams, so the cue on screen at the moment of the
    /// pick was already read and dropped — nothing shows until the next dialogue line.
    /// VLC's MKV demuxer indexes every subtitle block as a seekpoint and rewinds each
    /// selected track to the greatest one ≤ the target, so a seek to where we already are
    /// re-emits the live cue. It has to come AFTER the selection, or it re-reads packets
    /// for a stream libvlc is still dropping.
    @Test("selecting a track re-seeks to the current position, after the write")
    func selectingATrackReseeksToTheLiveCue() async throws {
        let spy = spyOfferingOneTrack()
        let engine = VLCKitEngine(control: spy)
        try await engine.load(.fixture())
        await engine.play()
        spy.advanceClock(toMs: 42_000)
        try await requireEventually(
            { CMTimeGetSeconds(engine.currentTime) == 42 }, "the poll never ticked"
        )

        await engine.setSubtitleTrack(
            VLCKitEngine.buildSubtitleTrack(id: "3", name: "English", language: nil)
        )

        #expect(spy.orderedWrites == [.subtitleTrack(3), .seek(42_000)])
        await engine.teardown()
    }

    /// Off selects nothing, so there is no dropped cue to recover — and a seek there would
    /// be a re-buffer the user asked for by turning subtitles OFF.
    @Test("turning subtitles off does not re-seek")
    func turningSubtitlesOffDoesNotReseek() async throws {
        let spy = spyOfferingOneTrack()
        let engine = VLCKitEngine(control: spy)
        try await engine.load(.fixture())
        await engine.play()
        spy.advanceClock(toMs: 42_000)
        try await requireEventually(
            { CMTimeGetSeconds(engine.currentTime) == 42 }, "the poll never ticked"
        )

        await engine.setSubtitleTrack(nil)

        #expect(spy.orderedWrites == [.subtitleTrack(-1)])
        await engine.teardown()
    }

    /// The resume seek has not reached the input yet, so there is no position worth
    /// re-seeking to — and issuing one would cancel the resume (`seek(to:)` clears
    /// `pendingStartMs` by design). `currentTime` is `.invalid` for exactly that window,
    /// which is why it is the gate.
    @Test("a selection inside the resume window leaves the pending resume seek alone")
    func selectingATrackDuringResumeDoesNotReseek() async throws {
        let spy = spyOfferingOneTrack()
        spy.stubbedIsSeekable = false   // hold the resume seek in its readiness window
        let engine = VLCKitEngine(control: spy)
        try await engine.load(.fixture(startTime: CMTime(seconds: 90, preferredTimescale: 1_000)))

        await engine.setSubtitleTrack(
            VLCKitEngine.buildSubtitleTrack(id: "3", name: "English", language: nil)
        )

        #expect(spy.orderedWrites == [.subtitleTrack(3)])
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

        try await pollUntil { spy.currentVideoSubTitleDelay == -250_000 }
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

        try await pollUntil({ spy.stopCalls == 1 })
        // The bug nils the reference the moment A returns; the fix keeps joining B.
        try await pollUntil({ engine.pendingStopTask == nil }, timeout: .milliseconds(500))
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

/// The engine half of the seek-settle contract (`PositionProvenance`): a beat is `.observed`
/// only when its position is the decoder's own clock with no seek outstanding. VLC's holds
/// publish `.projected` guesses — the seek's target echoed back, then an extrapolation off it —
/// and used to ship them indistinguishable from a real landing, which is what let an expired
/// hold republish the PRE-seek clock as `.playing`. Nothing here is ever `.stale`: while a hold
/// stands the engine publishes the held value, so libvlc's lying clock never reaches the wire.
@Suite("VLCKitEngine — the seek-settle contract", .timeLimit(.minutes(2)))
@MainActor
struct VLCKitSeekSettleTests {

    private func playingEngine(
        _ spy: SpyVLCPlayer, atMs: Int32, stallDeadline: Duration = .seconds(45)
    ) async throws -> VLCKitEngine {
        spy.advanceClock(toMs: atMs)
        let engine = VLCKitEngine(control: spy, stallDeadline: stallDeadline)
        try await engine.load(.fixture())
        await engine.play()
        return engine
    }

    @Test("every beat from seek() until convergence is projected; the first converged beat is observed")
    func holdBeatsAreProjectedUntilTheClockConverges() async throws {
        let spy = SpyVLCPlayer()
        let engine = try await playingEngine(spy, atMs: 10_000)
        let log = PositionBeatLog(engine)

        // Not a vacuous pass: a live beat off the untouched clock IS observed.
        try await requireEventually({ log.beats.contains(PositionBeat(.playing(
            10, duration: .indefinite
        ))!) }, "the poll never published an observed live beat")

        await engine.seek(to: CMTime(seconds: 60, preferredTimescale: 1_000))
        // The seek echo plus at least two hold beats — libvlc's clock is still at 10s
        // throughout (the spy models 3.x: a `time` write does not move the getter).
        try await requireEventually({ log.from(60).count >= 3 }, "the hold never published")
        #expect(log.from(60).allSatisfy { $0.provenance == .projected })
        #expect(log.beats.allSatisfy { $0.seconds >= 60 || $0.seconds == 10 })   // never a mid-seek clock
        // The whole point of three values: VLC suppresses the lying clock rather than shipping
        // it, so nothing on this engine is ever `.stale`.
        #expect(log.beats.allSatisfy { $0.provenance != .stale })

        spy.advanceClock(toMs: 60_000)   // libvlc's time-changed event finally lands on the target
        try await requireEventually({ log.from(60).contains { $0.provenance == .observed } },
                              "the hold never released")

        let observed = try #require(log.from(60).first { $0.provenance == .observed })
        #expect(observed.seconds == 60)
        #expect(observed.isBuffering == false)
        log.stop()
        await engine.teardown()
    }

    /// The lie, end to end. The hold's poll budget runs out after ~5s; releasing there used to
    /// republish `player.time` as a landed `.playing` — and on a source that never republishes
    /// time at the new offset that value is the position the user seeked AWAY from, so the bar
    /// snapped back 7 minutes and the resume point followed. The hold now outlasts its budget
    /// while the clock is provably behind, and the beat it finally releases on carries the raw
    /// clock, labelled `.observed`.
    ///
    /// Run with `timeWritesMoveTheClock`, which is what makes it an assertion about the SAMPLING
    /// ORDER rather than about libvlc's timing. The pre-seek clock has to be read BEFORE the
    /// `setTime`; read after, it is right only while 3.x's cached getter has not taken the
    /// request yet, and a build that takes it records the TARGET as the pre-seek clock — a value
    /// no later reading can ever be nearer the target than, so the hold either releases onto the
    /// stale clock or (with the give-up as it now stands) never releases at all.
    @Test("an expired hold never republishes the pre-seek clock, and its raw beat is observed")
    func expiredHoldNeverRepublishesThePreSeekClock() async throws {
        let spy = SpyVLCPlayer()
        spy.timeWritesMoveTheClock = true
        let engine = try await playingEngine(spy, atMs: 10_000)
        let log = PositionBeatLog(engine)

        await engine.seek(to: CMTime(seconds: 480, preferredTimescale: 1_000))
        // libvlc's cached clock took the request; the input then republishes what the demux is
        // REALLY at, which after a seek is still the pre-seek position for seconds on wmv/SMB.
        // Same MainActor turn as the write — `seek(to:)` has no suspension point — so no poll
        // can observe the value in between.
        spy.advanceClock(toMs: 10_000)

        // 10 polls ≈ 5s is the budget; wait past it with the clock still parked at 10s.
        try await requireEventually({ log.from(480).count >= 12 },
                              "the hold never outlasted its poll budget",
                              timeout: CITimeScale.seconds(20))
        #expect(log.from(480).allSatisfy { $0.provenance == .projected })
        #expect(log.beats.contains { $0.seconds == 10 && $0.provenance != .observed } == false)
        // The whole point: not one beat after the seek carries the pre-seek position.
        #expect(log.from(0).filter { $0.seconds < 480 }.allSatisfy { $0.seconds == 10 })

        // libvlc republishes at last — nowhere near the target (a clamped/keyframe-snapped
        // landing). That is the decoder's own clock, so it ships as-is, `.observed`.
        spy.advanceClock(toMs: 300_000)
        try await requireEventually({ log.beats.contains { $0.provenance == .observed && $0.seconds == 300 } },
                              "the expired hold never released onto the moved clock",
                              timeout: CITimeScale.seconds(10))
        log.stop()
        await engine.teardown()
    }

    /// A speed change is NOT a seek, and the flush bridge's anchor is not a guess: it is the
    /// current clock frozen while libvlc re-decodes at the new rate, so the position is exactly
    /// where the media is. Labelled `.projected` it read to the app as an unresolved seek, which
    /// skips the stall debounce — every 1.25× tap threw the buffering scrim up on the spot.
    @Test("a rate-flush bridge beat is observed — the anchor is the clock, not a projection")
    func rateFlushBridgeBeatIsObserved() async throws {
        let spy = SpyVLCPlayer()
        let engine = try await playingEngine(spy, atMs: 10_000)
        let log = PositionBeatLog(engine)

        await engine.setRate(1.5)

        try await requireEventually({ log.beats.contains { $0.isBuffering } },
                              "the flush bridge never published")
        let bridge = try #require(log.beats.first { $0.isBuffering })
        #expect(bridge.seconds == 10)          // the anchor: where the clock already was
        #expect(bridge.provenance == .observed)
        log.stop()
        await engine.teardown()
    }

    /// The hold can now outlast its poll budget (it will not release onto a clock that never
    /// republished), so nothing below the poll's guard chain bounds a share that dies mid-seek —
    /// the stall detector never runs while the hold `continue`s. The `.buffer` branch has to arm
    /// the watchdog itself, or the session buffers forever instead of failing into the retry
    /// scrim. Flat demux bytes are the starving signal; the deadline is injected so the failure
    /// is reachable in a test.
    @Test("a hold whose fetch has stopped fails the session on the stall watchdog")
    func starvingHoldFailsTheSession() async throws {
        let spy = SpyVLCPlayer()   // demuxBytesPerPoll == 0: nothing is being consumed at all
        let engine = try await playingEngine(spy, atMs: 10_000, stallDeadline: .seconds(1))
        let log = PositionBeatLog(engine)

        await engine.seek(to: CMTime(seconds: 480, preferredTimescale: 1_000))

        try await requireEventually({ log.failure != nil },
                              "the starving hold never bounded the session",
                              timeout: CITimeScale.seconds(20))
        #expect(log.failure == .networkStalled)
        #expect(log.from(480).contains { $0.isBuffering })   // …behind the honest scrim
        log.stop()
        await engine.teardown()
    }

    /// The other side, and the reason the arm is on BYTES rather than on the hold itself: a
    /// healthy hold on wmv/SMB routinely outlives its poll budget with the clock parked, because
    /// libvlc has not republished time at the new offset yet. Frames are landing the whole time.
    /// Failing that session would kill playback that is working.
    @Test("a hold whose fetch is still trickling never fails, however long it holds")
    func tricklingHoldNeverFails() async throws {
        let spy = SpyVLCPlayer()
        spy.demuxBytesPerPoll = 1   // one byte per poll: the clock is behind, the fetch is not
        let engine = try await playingEngine(spy, atMs: 10_000, stallDeadline: .seconds(1))
        let log = PositionBeatLog(engine)

        await engine.seek(to: CMTime(seconds: 480, preferredTimescale: 1_000))

        // Counted in POLLS, not wall time: 8 of them is ≥4s of holding against a 1s deadline,
        // and a slow runner makes this negative assertion stronger rather than flakier.
        try await requireEventually({ log.from(480).count >= 8 }, "the hold never published",
                              timeout: CITimeScale.seconds(20))
        #expect(log.failure == nil)
        #expect(log.from(480).allSatisfy { $0.isBuffering == false })   // and no scrim either
        log.stop()
        await engine.teardown()
    }

    /// A stall armed by the play-intent reassert (the device-observed VideoToolbox post-scrub
    /// wedge) must outlive whatever the seek hold publishes. The hold used to disarm
    /// `isStalled` on every healthy tick — its job was to drop its OWN starving-hold arm — and
    /// took the reassert's with it, so a seek committed into a wedged input lost its 45s
    /// failure and buffered forever behind a bar that kept extrapolating. The hold decides what
    /// to publish; the stall flag is not its to touch.
    @Test("a reassert-armed stall is not disarmed by a healthy hold tick")
    func reassertArmedStallSurvivesAHealthyHold() async throws {
        let spy = SpyVLCPlayer()
        spy.demuxBytesPerPoll = 1   // the fetch is healthy throughout: nothing else can arm a stall
        let engine = try await playingEngine(spy, atMs: 10_000, stallDeadline: .seconds(2))
        let log = PositionBeatLog(engine)

        await engine.seek(to: CMTime(seconds: 480, preferredTimescale: 1_000))
        // The device shape: the input drops the resume and sits paused against play intent
        // while the seek is still settling. One reassert tick arms the watchdog and re-issues
        // play() — which the spy honours — so every tick after it is an ordinary healthy hold.
        spy.stubbedIsPlaying = false
        spy.stubbedState = .paused

        try await requireEventually({ log.from(480).count >= 4 },
                                    "the hold never published, so nothing could have disarmed",
                                    timeout: CITimeScale.seconds(20))
        #expect(log.from(480).contains { $0.provenance == .projected })   // a healthy hold, extrapolating
        try await requireEventually({ log.failure != nil },
                                    "the hold disarmed the reassert's stall: no failure ever landed",
                                    timeout: CITimeScale.seconds(20))
        #expect(log.failure == .networkStalled)
        log.stop()
        await engine.teardown()
    }

    /// The hold that never ends. `seekHoldShouldRelease`'s expiry is conditional — it will not
    /// release onto a clock that never left the pre-seek neighbourhood — and a BACKWARD seek
    /// satisfies that condition forever: libvlc's clock free-runs FORWARD off the pre-seek
    /// position, so every reading is further from the target than from the origin, at every
    /// poll count. The fetch is healthy the whole time, so the `.buffer` arm never fires and
    /// the stall detector (which needs BOTH axes frozen) never trips either: nothing bounded
    /// it, and the bar rode an extrapolation off a target the media never reached until the
    /// app's own 20s watchdog fired on a projection.
    ///
    /// The abandon cap is the floor: 30 polls ≈ 15s from the ORIGINAL seek, after which the
    /// engine gives up and publishes the honest raw clock — labelled `.observed`, because with
    /// the hold gone there is no seek of the engine's outstanding.
    @Test("a backward seek on a never-republishing clock releases onto the raw clock at the abandon cap")
    func abandonedHoldReleasesOntoTheRawClock() async throws {
        let spy = SpyVLCPlayer()
        spy.demuxBytesPerPoll = 1   // healthy fetch: neither the `.buffer` arm nor the detector fires
        let engine = try await playingEngine(spy, atMs: 600_000, stallDeadline: .seconds(120))
        let log = PositionBeatLog(engine)

        await engine.seek(to: CMTime(seconds: 60, preferredTimescale: 1_000))
        // The extrapolation off the target (60s, climbing 0.5s a tick); the clock stays parked
        // at 600s, which is 09:00 the WRONG side of the target.
        let heldBeats = { log.beats.filter { $0.seconds < 500 } }
        try await requireEventually({ heldBeats().count >= 6 }, "the hold never published",
                                    timeout: CITimeScale.seconds(20))
        #expect(heldBeats().allSatisfy { $0.provenance == .projected })

        // 30 polls ≈ 15s: bounded generously above it, because the claim is "it ends", not
        // "it ends on this tick".
        try await requireEventually({
            log.beats.last.map { $0.seconds == 600 && $0.provenance == .observed } ?? false
        }, "the hold never abandoned the seek", timeout: CITimeScale.seconds(40))

        // …and it released AFTER holding, not by never having held: the last extrapolation
        // precedes the release rather than following it.
        let released = try #require(log.beats.lastIndex { $0.seconds == 600 })
        let lastHeld = try #require(log.beats.lastIndex { $0.seconds < 500 })
        #expect(lastHeld < released)
        #expect(heldBeats().count >= 25, "released well before the cap: \(heldBeats().count) held beats")
        log.stop()
        await engine.teardown()
    }

    /// `pause()` publishes its own beat (the poll is silent while paused) from the same held
    /// position the hold extrapolates — a forward guess off the target, and it has to say so.
    @Test("a pause landing inside the hold publishes a projected beat")
    func pauseInsideTheHoldIsProjected() async throws {
        let spy = SpyVLCPlayer()
        let engine = try await playingEngine(spy, atMs: 10_000)
        let log = PositionBeatLog(engine)

        await engine.seek(to: CMTime(seconds: 60, preferredTimescale: 1_000))
        await engine.pause()
        // The seek echo and the pause beat both ride the stream; wait for the collector.
        try await requireEventually({ log.from(60).count >= 2 }, "the pause beat never landed")
        let paused = try #require(log.from(60).last)
        #expect(paused.seconds == 60)
        #expect(paused.provenance == .projected)

        log.stop()
        await engine.teardown()
    }
}
