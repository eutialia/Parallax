import Testing
@testable import ParallaxFeatures

/// A live session's press: commands accepted, nothing pending, no segment button.
@MainActor private func live(shown: Double = 0.5, pendingSeek: Bool = false, segmentButton: Bool = false,
                  accepts: Bool = true, playing: Bool = true) -> PlayerTVHUDContext {
    PlayerTVHUDContext(shownProgress: shown, durationSeconds: 100, acceptsPlaybackCommands: accepts,
                       isPlaying: playing, segmentPromptShowing: segmentButton, hasPendingSeek: pendingSeek)
}

/// A HUD that has begun playback and sits in `state`, reached through real inputs.
@MainActor private func begun(in state: PlayerHUDState) -> PlayerTVHUD {
    var hud = PlayerTVHUD()
    _ = hud.acceptanceChanged(to: true)
    switch state {
    case .floor: break
    case .fullHUD: _ = hud.send(.click(.up), live())
    case .clickSeek: _ = hud.send(.click(.right), live())
    case .swipeScrub(let chrome):
        if chrome { _ = hud.send(.click(.up), live()); hud.scrubberFocused = true }
        _ = hud.send(.swipeHorizontal(deltaProgress: 0.01), live())
    }
    #expect(hud.state == state)
    return hud
}

@MainActor
@Suite("tvOS HUD shell")
struct PlayerTVHUDTests {
    @Test("folding the chrome takes its panel and scrubber focus with it; a swipe on the chrome's scrubber keeps them")
    func foldClearsTheChromeInteraction() {
        var hud = begun(in: .fullHUD)
        hud.interaction.panel = PlayerPanel(kind: .subtitles)
        hud.scrubberFocused = true

        _ = hud.send(.swipeHorizontal(deltaProgress: 0.01), live())
        #expect(hud.state == .swipeScrub(chrome: true))
        #expect(hud.interaction.menuOpen)

        _ = hud.send(.menu, live())
        _ = hud.send(.menu, live())
        #expect(hud.state == .floor)
        #expect(hud.interaction == PlayerHUDInteraction())
        #expect(!hud.scrubberFocused)
    }

    @Test("a remount after playback began starts on the floor with nothing open")
    func remountAfterRetry() {
        var hud = begun(in: .fullHUD)
        hud.interaction.debugOpen = true
        #expect(hud.surfaceAppeared() == [.dropPendingSeek])
        #expect(hud.state == .floor)
        #expect(!hud.interaction.menuOpen)
    }

    @Test("the initial load's chrome drops to the floor once; a later re-buffer keeps the HUD")
    func initialHandOff() {
        var hud = PlayerTVHUD()
        #expect(hud.surfaceAppeared() == [.dropPendingSeek])
        #expect(hud.state == .fullHUD)
        _ = hud.acceptanceChanged(to: true)
        #expect(hud.state == .floor)

        _ = hud.send(.click(.up), live())
        _ = hud.acceptanceChanged(to: false)
        _ = hud.acceptanceChanged(to: true)
        #expect(hud.state == .fullHUD)
    }

    @Test("losing acceptance mid-scrub returns to where the scrub began and drops what it stranded",
          arguments: [(PlayerHUDState.swipeScrub(chrome: false), PlayerHUDState.floor),
                      (.swipeScrub(chrome: true), .fullHUD),
                      (.clickSeek, .floor)])
    func acceptanceLossFoldsTheScrub(from state: PlayerHUDState, to home: PlayerHUDState) {
        var hud = begun(in: state)
        #expect(hud.acceptanceChanged(to: false) == [.dropPendingSeek, .cancelIdleTimer, .cancelPreview, .endScrubHold])
        #expect(hud.state == home)
    }

    @Test("before anything resolves, Back exits and transport presses do nothing")
    func coldStart() {
        var hud = PlayerTVHUD()
        let cold = live(accepts: false, playing: false)
        #expect(hud.send(.select, cold) == [])
        #expect(hud.send(.swipeHorizontal(deltaProgress: 0.1), cold) == [])
        #expect(hud.send(.menu, cold) == [.player([.exit])])
        #expect(hud.state == .fullHUD)
    }

    @Test("Back during a mid-session reload folds the HUD instead of exiting")
    func reloadBackFolds() {
        var hud = begun(in: .fullHUD)
        #expect(hud.send(.menu, live(accepts: false)) == [.restartIdleTimer])
        #expect(hud.state == .floor)
    }

    @Test("the segment button borrows Select and spends itself on a reveal; Back and pans pass through")
    func segmentButtonIntercept() {
        var hud = begun(in: .floor)
        #expect(hud.send(.select, live(segmentButton: true)) == [.activateSegmentPrompt, .restartIdleTimer])
        #expect(hud.state == .floor)

        #expect(hud.send(.click(.down), live(segmentButton: true)) == [.expireSegmentPrompt, .restartIdleTimer])
        #expect(hud.state == .fullHUD)

        var floor = begun(in: .floor)
        #expect(floor.send(.menu, live(segmentButton: true)) == [.player([.exit]), .restartIdleTimer])
    }

    @Test("a click step arms one debounced commit, which a swipe drops and a fold to the floor lands")
    func pendingClickStep() {
        var hud = begun(in: .floor)
        let step = PlayerHUDTuning.clickStepSeconds / 100
        #expect(hud.send(.click(.right), live()) == [
            .player([.preview(progress: 0.5 + step)]), .scheduleClickSeek(progress: 0.5 + step), .restartIdleTimer,
        ])

        var swiped = hud
        #expect(swiped.send(.swipeHorizontal(deltaProgress: 0.01), live(pendingSeek: true)).first == .dropPendingSeek)
        #expect(hud.send(.menu, live(pendingSeek: true)) == [.flushPendingSeek, .restartIdleTimer])
    }

    @Test("under the chrome only a horizontal pan on the focused scrubber reaches the reducer")
    func panRouting() {
        var hud = begun(in: .fullHUD)
        #expect(!hud.routesPan(.swipeHorizontal(deltaProgress: 0.01)))
        hud.scrubberFocused = true
        #expect(hud.routesPan(.swipeHorizontal(deltaProgress: 0.01)))
        #expect(!hud.routesPan(.swipeVertical))
        #expect(begun(in: .floor).routesPan(.swipeVertical))
    }

    @Test("the full HUD auto-hides only while playing, with no panel and no seek alive")
    func idleTimeouts() {
        #expect(begun(in: .floor).idleTimeout(desiredPlaying: true, flightAlive: false) == nil)
        #expect(begun(in: .swipeScrub(chrome: false)).idleTimeout(desiredPlaying: true, flightAlive: true)
                == SeekCommitCoalescer.interval)
        #expect(begun(in: .clickSeek).idleTimeout(desiredPlaying: false, flightAlive: true) == .seconds(4))

        var hud = begun(in: .fullHUD)
        #expect(hud.idleTimeout(desiredPlaying: true, flightAlive: false) == .seconds(4))
        #expect(hud.idleTimeout(desiredPlaying: false, flightAlive: false) == nil)
        #expect(hud.idleTimeout(desiredPlaying: true, flightAlive: true) == nil)
        hud.interaction.panel = PlayerPanel(kind: .audio)
        #expect(hud.idleTimeout(desiredPlaying: true, flightAlive: false) == nil)
    }
}
