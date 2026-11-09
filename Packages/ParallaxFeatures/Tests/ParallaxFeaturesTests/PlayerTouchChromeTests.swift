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
        chrome.interaction.dragScrubbing = true
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
        #expect(chrome.interaction.dragScrubbing == true)
        #expect(chrome.interaction.menuOpen == true)
        #expect(chrome.pullToDismissEnabled == false)
    }
}
