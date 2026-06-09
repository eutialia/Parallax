import Testing
@testable import Parallax

struct PlayerHUDReducerTests {
    // duration 100s → a 10s click step is exactly 0.1 of progress, so click maths land
    // on binary-exact values and the enum's Double equality stays reliable.
    private let playing = ReduceContext(liveProgress: 0.5, durationSeconds: 100, isPlaying: true)
    private let paused = ReduceContext(liveProgress: 0.5, durationSeconds: 100, isPlaying: false)

    // MARK: floor

    @Test("floor: horizontal swipe enters scrub, pauses, seeds from live + delta")
    func floorSwipeEntersScrub() {
        let (state, fx) = reduce(.floor, .swipeHorizontal(deltaProgress: 0.25), playing)
        #expect(state == .swipeScrub(progress: 0.75, wasPlaying: true))
        #expect(fx == [.pause])
    }

    @Test("floor: horizontal swipe clamps the seeded progress to 0...1")
    func floorSwipeClamps() {
        let (state, _) = reduce(.floor, .swipeHorizontal(deltaProgress: 0.9), paused)
        #expect(state == .swipeScrub(progress: 1.0, wasPlaying: false))
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

    @Test("floor: left/right click enters clickSeek at an absolute target, no immediate seek")
    func floorClickSeeks() {
        // The seek itself is debounced by the view, so the reducer emits no effect.
        let (rightState, rightFx) = reduce(.floor, .click(.right), playing)
        #expect(rightState == .clickSeek(targetProgress: 0.6))
        #expect(rightFx.isEmpty)

        let (leftState, leftFx) = reduce(.floor, .click(.left), playing)
        #expect(leftState == .clickSeek(targetProgress: 0.4))
        #expect(leftFx.isEmpty)
    }

    @Test("floor: select (center) toggles play/pause, stays on floor")
    func floorSelectTogglesPlayPause() {
        #expect(reduce(.floor, .select, playing) == (PlayerHUDState.floor, [PlayerEffect.togglePlayPause]))
    }

    @Test("floor: menu exits the player")
    func floorMenuExits() {
        #expect(reduce(.floor, .menu, playing) == (PlayerHUDState.floor, [PlayerEffect.exit]))
    }

    @Test("floor: play/pause toggles, stays on floor")
    func floorPlayPauseToggles() {
        #expect(reduce(.floor, .playPause, playing) == (PlayerHUDState.floor, [PlayerEffect.togglePlayPause]))
    }

    // MARK: clickSeek

    @Test("clickSeek: consecutive clicks accumulate the target deterministically, no per-click seek")
    func clickSeekAccumulates() {
        let (state, fx) = reduce(.clickSeek(targetProgress: 0.6), .click(.right), playing)
        #expect(state == .clickSeek(targetProgress: 0.7))
        #expect(fx.isEmpty)

        let (back, backFx) = reduce(.clickSeek(targetProgress: 0.2), .click(.left), playing)
        #expect(back == .clickSeek(targetProgress: 0.1))
        #expect(backFx.isEmpty)
    }

    @Test("clickSeek: target clamps to 0...1 at the ends")
    func clickSeekClamps() {
        #expect(reduce(.clickSeek(targetProgress: 0.95), .click(.right), playing).0 == .clickSeek(targetProgress: 1.0))
        #expect(reduce(.clickSeek(targetProgress: 0.05), .click(.left), playing).0 == .clickSeek(targetProgress: 0.0))
    }

    @Test("clickSeek: horizontal swipe falls back to analog scrub and pauses")
    func clickSeekToSwipe() {
        let (state, fx) = reduce(.clickSeek(targetProgress: 0.4), .swipeHorizontal(deltaProgress: 0.1), playing)
        #expect(state == .swipeScrub(progress: 0.5, wasPlaying: true))
        #expect(fx == [.pause])
    }

    @Test("clickSeek: vertical swipe / up-down click opens full HUD")
    func clickSeekToHUD() {
        #expect(reduce(.clickSeek(targetProgress: 0.4), .swipeVertical, playing).0 == .fullHUD)
        #expect(reduce(.clickSeek(targetProgress: 0.4), .click(.up), playing).0 == .fullHUD)
    }

    @Test("clickSeek: select toggles play/pause and returns to floor")
    func clickSeekSelectToggles() {
        #expect(reduce(.clickSeek(targetProgress: 0.4), .select, playing) == (PlayerHUDState.floor, [PlayerEffect.togglePlayPause]))
    }

    @Test("clickSeek: menu and idle hide the bar back to floor")
    func clickSeekDismisses() {
        #expect(reduce(.clickSeek(targetProgress: 0.4), .menu, playing) == (PlayerHUDState.floor, []))
        #expect(reduce(.clickSeek(targetProgress: 0.4), .idle, playing) == (PlayerHUDState.floor, []))
    }

    // MARK: swipeScrub

    @Test("scrub: horizontal swipe adjusts the head, keeps wasPlaying, no effect")
    func scrubAdjusts() {
        let (state, fx) = reduce(.swipeScrub(progress: 0.5, wasPlaying: true),
                                 .swipeHorizontal(deltaProgress: -0.25), playing)
        #expect(state == .swipeScrub(progress: 0.25, wasPlaying: true))
        #expect(fx.isEmpty)
    }

    @Test("scrub: select confirms seek + resumes when was playing, returns to floor")
    func scrubSelectConfirmsResumes() {
        let (state, fx) = reduce(.swipeScrub(progress: 0.3, wasPlaying: true), .select, playing)
        #expect(state == .floor)
        #expect(fx == [.seek(progress: 0.3), .play])
    }

    @Test("scrub: select confirms seek without resume when it was paused")
    func scrubSelectConfirmsNoResume() {
        let (_, fx) = reduce(.swipeScrub(progress: 0.3, wasPlaying: false), .select, paused)
        #expect(fx == [.seek(progress: 0.3)])
    }

    @Test("scrub: vertical swipe and click confirm seek and open full HUD")
    func scrubConfirmToHUD() {
        #expect(reduce(.swipeScrub(progress: 0.2, wasPlaying: true), .swipeVertical, playing).0 == .fullHUD)
        #expect(reduce(.swipeScrub(progress: 0.2, wasPlaying: true), .click(.up), playing).0 == .fullHUD)
        #expect(reduce(.swipeScrub(progress: 0.2, wasPlaying: false), .click(.left), paused).1 == [.seek(progress: 0.2)])
    }

    @Test("scrub: menu cancels — no seek, resumes if it was playing, back to floor")
    func scrubMenuCancels() {
        #expect(reduce(.swipeScrub(progress: 0.9, wasPlaying: true), .menu, playing) == (PlayerHUDState.floor, [PlayerEffect.play]))
        #expect(reduce(.swipeScrub(progress: 0.9, wasPlaying: false), .menu, paused) == (PlayerHUDState.floor, []))
    }

    @Test("scrub: idle commits the scrub — seeks to the preview head so a missed Select can't lose it")
    func scrubIdleCommits() {
        #expect(reduce(.swipeScrub(progress: 0.9, wasPlaying: true), .idle, playing)
                == (PlayerHUDState.floor, [PlayerEffect.seek(progress: 0.9), PlayerEffect.play]))
        #expect(reduce(.swipeScrub(progress: 0.9, wasPlaying: false), .idle, paused)
                == (PlayerHUDState.floor, [PlayerEffect.seek(progress: 0.9)]))
    }

    // MARK: fullHUD

    @Test("fullHUD: menu hides to floor (does not exit)")
    func hudMenuHides() {
        #expect(reduce(.fullHUD, .menu, playing) == (PlayerHUDState.floor, []))
    }

    @Test("fullHUD: idle auto-hides to floor")
    func hudIdleHides() {
        #expect(reduce(.fullHUD, .idle, playing) == (PlayerHUDState.floor, []))
    }

    @Test("fullHUD: play/pause toggles, stays in HUD")
    func hudPlayPause() {
        #expect(reduce(.fullHUD, .playPause, playing) == (PlayerHUDState.fullHUD, [PlayerEffect.togglePlayPause]))
    }

    @Test("fullHUD: horizontal swipe (view-gated to scrubber focus) drops into analog scrub and pauses")
    func hudSwipeEntersScrub() {
        let (state, fx) = reduce(.fullHUD, .swipeHorizontal(deltaProgress: 0.25), playing)
        #expect(state == .swipeScrub(progress: 0.75, wasPlaying: true))
        #expect(fx == [.pause])

        let (pausedState, pausedFx) = reduce(.fullHUD, .swipeHorizontal(deltaProgress: -0.25), paused)
        #expect(pausedState == .swipeScrub(progress: 0.25, wasPlaying: false))
        #expect(pausedFx == [.pause])
    }

    @Test("fullHUD: vertical swipe/click/select are no-ops (handled natively)")
    func hudNativeNoOps() {
        #expect(reduce(.fullHUD, .swipeVertical, playing) == (PlayerHUDState.fullHUD, []))
        #expect(reduce(.fullHUD, .click(.left), playing) == (PlayerHUDState.fullHUD, []))
        #expect(reduce(.fullHUD, .select, playing) == (PlayerHUDState.fullHUD, []))
    }
}
