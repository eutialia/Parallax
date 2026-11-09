import Foundation
import Testing
import ParallaxCore
@testable import ParallaxFeatures

@MainActor
@Suite("Touch player chrome")
struct PlayerTouchChromeTests {
    /// The chrome the user left when the stream died: hidden, a panel open, a finger on the bar.
    private func busyChrome() -> PlayerTouchChrome {
        var chrome = PlayerTouchChrome()
        chrome.visible = false
        chrome.interaction.panel = PlayerPanel(kind: .audio)
        _ = chrome.scrubDragChanged()
        return chrome
    }

    @Test("a failed stream shows the status bar and frees pull-to-dismiss over the error scrim",
          arguments: [PlayerViewModel.Phase.playing, .loading])
    func failureReleasesTheSystemChrome(from phase: PlayerViewModel.Phase) {
        var chrome = busyChrome()
        chrome.phaseChanged(from: phase, to: .failed(.playback(.unsupportedFormat)))

        #expect(chrome.statusBarHidden == false)
        #expect(chrome.systemOverlaysVisible == true)
        #expect(chrome.pullToDismissEnabled == true)
    }

    @Test("a mid-session reload keeps the finger's drag and the open panel")
    func reloadKeepsTheInteraction() {
        var chrome = busyChrome()
        chrome.phaseChanged(from: .playing, to: .loading)

        #expect(chrome.visible == true)
        #expect(chrome.dragScrubbing == true)
        #expect(chrome.interaction.menuOpen == true)
        #expect(chrome.pullToDismissEnabled == false)
    }

    // MARK: Taps

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private let left = CGPoint(x: 10, y: 100)
    private let step = PlayerHUDTuning.clickStepSeconds

    private func tap(_ chrome: inout PlayerTouchChrome, _ zone: PlayerSeekDirection?,
                     after seconds: TimeInterval) -> [PlayerTouchEffect] {
        chrome.tap(zone: zone, at: left, now: t0.addingTimeInterval(seconds),
                   playbackReady: true, durationKnown: true)
    }

    @Test("a lone edge tap toggles at once; the pair's second tap hides the chrome and steps")
    func doubleTapPairs() {
        var chrome = PlayerTouchChrome()
        #expect(tap(&chrome, .backward, after: 0) == [])
        #expect(chrome.visible == false)
        #expect(tap(&chrome, .backward, after: 1) == [.rearmHide])
        #expect(chrome.visible == true)

        #expect(tap(&chrome, .backward, after: 1.2) == [.stepSeek(seconds: -step), .rearmBurstDismissal])
        #expect(chrome.visible == false)
        #expect(chrome.burst?.seconds == Int(step))
    }

    @Test("a middle tap never pairs with the edge tap after it, and a slow second tap is a toggle")
    func unpairedTaps() {
        var chrome = PlayerTouchChrome()
        _ = tap(&chrome, nil, after: 0)
        #expect(tap(&chrome, .forward, after: 0.1) == [.rearmHide])

        _ = tap(&chrome, .forward, after: 1)
        #expect(tap(&chrome, .forward, after: 1 + PlayerTouchChrome.doubleTapWindow) == [.rearmHide])
        #expect(chrome.burst == nil)
    }

    @Test("taps in one third keep stepping the burst; a reversal starts a fresh one; the middle third is ignored")
    func burstAccumulates() throws {
        var chrome = PlayerTouchChrome()
        _ = tap(&chrome, .forward, after: 0)
        _ = tap(&chrome, .forward, after: 0.1)
        _ = tap(&chrome, .forward, after: 0.5)
        let extended = try #require(chrome.burst)
        #expect(extended.seconds == 2 * Int(step))
        #expect(extended.burstStart == t0.addingTimeInterval(0.1))

        #expect(tap(&chrome, nil, after: 0.6) == [])
        #expect(chrome.burst == extended)

        #expect(tap(&chrome, .backward, after: 0.7) == [.stepSeek(seconds: -step), .rearmBurstDismissal])
        let reversed = try #require(chrome.burst)
        #expect(reversed.seconds == Int(step))
        #expect(reversed.burstStart == t0.addingTimeInterval(0.7))
        #expect(reversed.trigger == extended.trigger + 1)
        #expect(chrome.visible == false)
    }

    /// A burst's debounced commit on a transcode is a reload, and leaving `.playing` brings the
    /// chrome back while the burst is still alive — over a hidden dome and bar.
    @Test("with the chrome shown over a live burst, a tap toggles the chrome instead of feeding the hidden burst",
          arguments: [PlayerSeekDirection?.none, .backward])
    func revealedChromeOwnsTaps(zone: PlayerSeekDirection?) throws {
        var chrome = PlayerTouchChrome()
        _ = tap(&chrome, .backward, after: 0)
        _ = tap(&chrome, .backward, after: 0.1)
        _ = try #require(chrome.burst)
        chrome.phaseChanged(from: .playing, to: .loading)
        #expect(!chrome.showsBurst(playbackReady: true))

        #expect(tap(&chrome, zone, after: 0.5) == [])
        #expect(chrome.visible == false)
    }

    /// Hiding the revealed chrome again must give a clean surface, not the covered burst's dome
    /// and stale "N seconds" for whatever is left of its dismissal timer.
    @Test("a burst the chrome covered does not come back when the chrome hides again")
    func coveredBurstDoesNotReturn() throws {
        var chrome = PlayerTouchChrome()
        _ = tap(&chrome, .backward, after: 0)
        _ = tap(&chrome, .backward, after: 0.1)
        _ = try #require(chrome.burst)
        chrome.phaseChanged(from: .playing, to: .loading)

        _ = tap(&chrome, nil, after: 0.5)
        #expect(chrome.visible == false)
        #expect(chrome.burst == nil)
        #expect(!chrome.showsBurst(playbackReady: true))
    }

    @Test("a player that can't seek just toggles on an edge double-tap")
    func notReadyToggles() {
        var chrome = PlayerTouchChrome()
        _ = chrome.tap(zone: .forward, at: left, now: t0, playbackReady: false, durationKnown: true)
        #expect(chrome.tap(zone: .forward, at: left, now: t0.addingTimeInterval(0.1),
                           playbackReady: false, durationKnown: true) == [.rearmHide])
        #expect(chrome.burst == nil)
    }

    // MARK: Drag-scrub

    @Test("a slow commit can't end the scrub of a drag that began after it")
    func scrubGenerations() {
        var chrome = PlayerTouchChrome()
        #expect(chrome.scrubDragChanged() == [.cancelHide, .dropPendingSeek, .cancelBurstDismissal, .beginScrubHold])
        #expect(chrome.scrubDragChanged() == [])
        #expect(chrome.scrubDragEnded(at: 0.25, canCommit: true) == [.rearmHide, .commitScrub(generation: 1, fraction: 0.25)])
        #expect(chrome.scrubInFlight && !chrome.dragScrubbing)

        _ = chrome.scrubDragChanged()
        chrome.scrubCommitLanded(generation: 1)
        #expect(chrome.dragScrubbing)

        _ = chrome.scrubDragEnded(at: 0.5, canCommit: true)
        chrome.scrubCommitLanded(generation: 2)
        #expect(chrome.scrub == .idle)
    }

    @Test("a drag with nothing to commit hands the bar back at once")
    func uncommittableDrag() {
        var chrome = PlayerTouchChrome()
        chrome.visible = false
        _ = chrome.scrubDragChanged()
        #expect(chrome.scrubDragEnded(at: 0.5, canCommit: false) == [.rearmHide, .cancelScrub])
        #expect(chrome.scrub == .idle)
        #expect(chrome.visible)
    }

    @Test("a finger on the bar holds the chrome: no auto-hide, and a second finger's tap can't toggle it")
    func dragHoldsTheChrome() {
        var chrome = PlayerTouchChrome()
        _ = chrome.scrubDragChanged()
        #expect(!chrome.autoHideEligible(pullDragging: false, desiredPlaying: true))
        #expect(chrome.statusBarHidden)
        #expect(!chrome.segmentPromptEnabled)
        #expect(tap(&chrome, nil, after: 0) == [])
        #expect(chrome.visible)
    }

    // MARK: Auto-hide

    @Test("the chrome auto-hides only while playing, with no menu, no drag and no pull")
    func autoHideEligibility() {
        var chrome = PlayerTouchChrome()
        #expect(chrome.autoHideEligible(pullDragging: false, desiredPlaying: true))
        #expect(!chrome.autoHideEligible(pullDragging: true, desiredPlaying: true))
        #expect(!chrome.autoHideEligible(pullDragging: false, desiredPlaying: false))
        chrome.interaction.debugOpen = true
        #expect(!chrome.autoHideEligible(pullDragging: false, desiredPlaying: true))
    }

    @Test("an auto-hide that fires after a panel opened or a finger took the bar leaves the chrome up")
    func staleAutoHideIsIgnored() {
        var underPanel = PlayerTouchChrome()
        underPanel.interaction.panel = PlayerPanel(kind: .audio)
        underPanel.autoHideFired()
        #expect(underPanel.visible)
        #expect(underPanel.interaction.menuOpen)

        var underDrag = PlayerTouchChrome()
        _ = underDrag.scrubDragChanged()
        underDrag.autoHideFired()
        #expect(underDrag.visible)
    }

    @Test("a tap with a menu open closes it and keeps the chrome up")
    func tapClosesMenus() {
        var chrome = PlayerTouchChrome()
        chrome.interaction.panel = PlayerPanel(kind: .speed)
        #expect(tap(&chrome, nil, after: 0) == [.rearmHide])
        #expect(chrome.visible)
        #expect(!chrome.interaction.menuOpen)
    }

    @Test("resuming re-arms only a chrome that shows; pausing always stops the timer")
    func resumeRearms() {
        var chrome = PlayerTouchChrome()
        #expect(chrome.hideTimer(after: .desiredPlaying(true)) == .rearmHide)
        #expect(chrome.hideTimer(after: .desiredPlaying(false)) == .cancelHide)
        chrome.visible = false
        #expect(chrome.hideTimer(after: .desiredPlaying(true)) == nil)
    }
}
