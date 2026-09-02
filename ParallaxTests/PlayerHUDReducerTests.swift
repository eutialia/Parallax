import Testing
@testable import Parallax

/// A reference duration whose click step lands on a binary-exact fraction, so the
/// state enum's `Double` equality stays reliable in the click-seek assertions.
private let referenceDuration: Double = 100
/// What ONE left/right click moves, as a fraction of `referenceDuration` — derived
/// from the reducer's own step constant, never re-typed as 0.1.
private let clickStep = PlayerHUDTuning.clickStepSeconds / referenceDuration

/// The reducer no longer branches on the transport at all — the still-frame hold leaves the
/// user's intent alone, and every exit from a scrub releases it — so one context covers every row.
private let baseCtx = ReduceContext(liveProgress: 0.5, durationSeconds: referenceDuration)

/// One cell of the state × event transition table.
private struct Transition: Sendable, CustomTestStringConvertible {
    let state: PlayerHUDState
    let event: RemoteEvent
    let ctx: ReduceContext
    let expected: PlayerHUDState
    let effects: [PlayerEffect]

    var testDescription: String {
        "\(state) + \(event) → \(expected) \(effects)"
    }
}

/// The deterministic cells: one row per (state, event) whose outcome is a plain
/// transition. The scrub/click-seek cells with their own rationale keep dedicated tests below.
private let transitionTable: [Transition] = [
    // floor — select/play-pause toggle in place, menu exits the player.
    .init(state: .floor, event: .select, ctx: baseCtx, expected: .floor, effects: [.togglePlayPause]),
    .init(state: .floor, event: .playPause, ctx: baseCtx, expected: .floor, effects: [.togglePlayPause]),
    .init(state: .floor, event: .menu, ctx: baseCtx, expected: .floor, effects: [.exit]),
    .init(state: .floor, event: .idle, ctx: baseCtx, expected: .floor, effects: []),
    // clickSeek — select commits to floor via a toggle; menu/idle just hide the bar.
    .init(state: .clickSeek(targetProgress: 0.4), event: .select, ctx: baseCtx, expected: .floor, effects: [.togglePlayPause]),
    .init(state: .clickSeek(targetProgress: 0.4), event: .menu, ctx: baseCtx, expected: .floor, effects: []),
    .init(state: .clickSeek(targetProgress: 0.4), event: .idle, ctx: baseCtx, expected: .floor, effects: []),
    // swipeScrub — play/pause commits the preview seek, releases the hold, and forwards the
    // toggle (an untested cell before this table existed).
    .init(state: .swipeScrub(progress: 0.3), event: .playPause, ctx: baseCtx,
          expected: .floor, effects: [.seek(progress: 0.3), .releaseHold, .togglePlayPause]),
    // fullHUD — menu/idle hide to floor (never exit); play/pause stays in chrome.
    .init(state: .fullHUD, event: .menu, ctx: baseCtx, expected: .floor, effects: []),
    .init(state: .fullHUD, event: .idle, ctx: baseCtx, expected: .floor, effects: []),
    .init(state: .fullHUD, event: .playPause, ctx: baseCtx, expected: .fullHUD, effects: [.togglePlayPause]),
]

struct PlayerHUDReducerTests {
    private let playing = baseCtx
    private let paused = baseCtx
    // Incomplete media whose runtime never resolved: `CMTimeGetSeconds(.indefinite)` is NaN, so
    // `durationSeconds > 0` is false and there's no scrubbable timeline.
    private let indeterminate = ReduceContext(liveProgress: 0, durationSeconds: .nan)

    @Test("every deterministic (state, event) cell lands where the table says",
          arguments: transitionTable)
    fileprivate func transitions(_ row: Transition) {
        let (state, effects) = reduce(row.state, row.event, row.ctx)
        #expect(state == row.expected)
        #expect(effects == row.effects)
    }

    // MARK: indeterminate duration (incomplete media)

    @Test("indeterminate: horizontal swipe is inert — never pauses into a dead scrub surface")
    func indeterminateSwipeIsInert() {
        let (state, fx) = reduce(.floor, .swipeHorizontal(deltaProgress: 0.3), indeterminate)
        #expect(state == .floor)
        #expect(fx.isEmpty)
    }

    @Test("indeterminate: left/right click is inert — no clickSeek state")
    func indeterminateClickIsInert() {
        let (l, lfx) = reduce(.floor, .click(.left), indeterminate)
        #expect(l == .floor); #expect(lfx.isEmpty)
        let (r, rfx) = reduce(.floor, .click(.right), indeterminate)
        #expect(r == .floor); #expect(rfx.isEmpty)
    }

    @Test("indeterminate: vertical / play-pause / menu stay live")
    func indeterminateNonScrubStillWorks() {
        #expect(reduce(.floor, .swipeVertical, indeterminate).0 == .fullHUD)
        #expect(reduce(.floor, .playPause, indeterminate).1 == [.togglePlayPause])
        #expect(reduce(.floor, .menu, indeterminate).1 == [.exit])
    }

    // MARK: floor

    @Test("floor: horizontal swipe enters scrub, holds the still frame, seeds from live + delta")
    func floorSwipeEntersScrub() {
        let (state, fx) = reduce(.floor, .swipeHorizontal(deltaProgress: 0.25), playing)
        #expect(state == .swipeScrub(progress: 0.75))
        #expect(fx == [.holdStillFrame])
    }

    @Test("floor: horizontal swipe clamps the seeded progress to 0...1")
    func floorSwipeClamps() {
        let (state, _) = reduce(.floor, .swipeHorizontal(deltaProgress: 0.9), paused)
        #expect(state == .swipeScrub(progress: 1.0))
    }

    @Test("floor: vertical swipe reveals full HUD")
    func floorVerticalRevealsHUD() {
        let (state, fx) = reduce(.floor, .swipeVertical, playing)
        #expect(state == .fullHUD)
        #expect(fx.isEmpty)
    }

    @Test("floor: up/down click reveals full HUD with no effect")
    func floorVerticalClickRevealsHUD() {
        #expect(reduce(.floor, .click(.up), playing).0 == .fullHUD)
        #expect(reduce(.floor, .click(.down), playing).0 == .fullHUD)
        #expect(reduce(.floor, .click(.up), playing).1.isEmpty)
    }

    @Test("floor: left/right click enters clickSeek one step from live progress, no immediate seek")
    func floorClickSeeks() {
        // The seek itself is debounced by the view, so the reducer emits no effect.
        let (rightState, rightFx) = reduce(.floor, .click(.right), playing)
        #expect(rightState == .clickSeek(targetProgress: playing.liveProgress + clickStep))
        #expect(rightFx.isEmpty)

        let (leftState, leftFx) = reduce(.floor, .click(.left), playing)
        #expect(leftState == .clickSeek(targetProgress: playing.liveProgress - clickStep))
        #expect(leftFx.isEmpty)
    }

    // MARK: clickSeek

    @Test("clickSeek: consecutive clicks accumulate the target deterministically, no per-click seek")
    func clickSeekAccumulates() {
        // Accumulation is off the CURRENT target, not off live progress.
        let (state, fx) = reduce(.clickSeek(targetProgress: 0.6), .click(.right), playing)
        #expect(state == .clickSeek(targetProgress: 0.6 + clickStep))
        #expect(fx.isEmpty)

        let (back, backFx) = reduce(.clickSeek(targetProgress: 0.2), .click(.left), playing)
        #expect(back == .clickSeek(targetProgress: 0.2 - clickStep))
        #expect(backFx.isEmpty)
    }

    @Test("clickSeek: target clamps to 0...1 at the ends")
    func clickSeekClamps() {
        #expect(reduce(.clickSeek(targetProgress: 0.95), .click(.right), playing).0 == .clickSeek(targetProgress: 1.0))
        #expect(reduce(.clickSeek(targetProgress: 0.05), .click(.left), playing).0 == .clickSeek(targetProgress: 0.0))
    }

    @Test("clickSeek: horizontal swipe falls back to analog scrub and holds the still frame")
    func clickSeekToSwipe() {
        let (state, fx) = reduce(.clickSeek(targetProgress: 0.4), .swipeHorizontal(deltaProgress: 0.1), playing)
        #expect(state == .swipeScrub(progress: 0.5))
        #expect(fx == [.holdStillFrame])
    }

    @Test("clickSeek: vertical swipe / up-down click opens full HUD")
    func clickSeekToHUD() {
        #expect(reduce(.clickSeek(targetProgress: 0.4), .swipeVertical, playing).0 == .fullHUD)
        #expect(reduce(.clickSeek(targetProgress: 0.4), .click(.up), playing).0 == .fullHUD)
    }

    // MARK: swipeScrub

    @Test("scrub: horizontal swipe adjusts the head, no effect")
    func scrubAdjusts() {
        let (state, fx) = reduce(.swipeScrub(progress: 0.5),
                                 .swipeHorizontal(deltaProgress: -0.25), playing)
        #expect(state == .swipeScrub(progress: 0.25))
        #expect(fx.isEmpty)
    }

    @Test("scrub: select confirms the seek and releases the hold, returns to floor")
    func scrubSelectConfirms() {
        let (state, fx) = reduce(.swipeScrub(progress: 0.3), .select, playing)
        #expect(state == .floor)
        #expect(fx == [.seek(progress: 0.3), .releaseHold])
    }

    @Test("scrub: vertical swipe and click confirm seek and open full HUD")
    func scrubConfirmToHUD() {
        #expect(reduce(.swipeScrub(progress: 0.2), .swipeVertical, playing).0 == .fullHUD)
        #expect(reduce(.swipeScrub(progress: 0.2), .click(.up), playing).0 == .fullHUD)
        #expect(reduce(.swipeScrub(progress: 0.2), .click(.left), paused).1 == [.seek(progress: 0.2), .releaseHold])
    }

    @Test("scrub: menu cancels — no seek, but the hold is still released")
    func scrubMenuCancels() {
        #expect(reduce(.swipeScrub(progress: 0.9), .menu, playing)
                == (PlayerHUDState.floor, [PlayerEffect.releaseHold]))
    }

    @Test("scrub: idle commits the scrub — seeks to the preview head so a missed Select can't lose it")
    func scrubIdleCommits() {
        #expect(reduce(.swipeScrub(progress: 0.9), .idle, playing)
                == (PlayerHUDState.floor, [PlayerEffect.seek(progress: 0.9), PlayerEffect.releaseHold]))
    }

    /// The rule the `.menu` cancel used to break, stated as a rule: a hold nothing releases is a
    /// frozen picture under a glyph that reads intent, and nothing self-heals it. The old
    /// `wasPlaying == false` cancel emitted no effect at all, so a Now Playing Play pressed
    /// mid-scrub left the engine held with `desiredPlaying == true`.
    @Test("scrub: EVERY exit from swipeScrub releases the hold",
          arguments: [RemoteEvent.select, .swipeVertical, .click(.up), .click(.left),
                      .menu, .idle, .playPause])
    func everyScrubExitReleasesTheHold(event: RemoteEvent) {
        let (state, fx) = reduce(.swipeScrub(progress: 0.4), event, playing)
        #expect(state != .swipeScrub(progress: 0.4))   // it IS an exit
        #expect(fx.contains(.releaseHold))
    }

    // MARK: fullHUD

    @Test("fullHUD: horizontal swipe (view-gated to scrubber focus) drops into analog scrub and holds")
    func hudSwipeEntersScrub() {
        let (state, fx) = reduce(.fullHUD, .swipeHorizontal(deltaProgress: 0.25), playing)
        #expect(state == .swipeScrub(progress: 0.75))
        #expect(fx == [.holdStillFrame])
    }

    @Test("fullHUD: vertical swipe/click/select are no-ops (handled natively)")
    func hudNativeNoOps() {
        #expect(reduce(.fullHUD, .swipeVertical, playing) == (PlayerHUDState.fullHUD, []))
        #expect(reduce(.fullHUD, .click(.left), playing) == (PlayerHUDState.fullHUD, []))
        #expect(reduce(.fullHUD, .select, playing) == (PlayerHUDState.fullHUD, []))
    }
}
