import Testing
import CoreGraphics
@testable import Parallax

@Suite struct PlayerMetricsTests {
    @Test func tvIsUnitScale() {
        #expect(PlayerMetrics(width: 1920).u == 1.0)
    }

    @Test func iPadScalesByWidthOver1920() {
        let u = PlayerMetrics(width: 1366).u
        #expect(abs(u - 0.7115) < 0.001)
    }

    @Test func clampsTinyWindowsToFloor() {
        #expect(PlayerMetrics(width: 480).u == 0.5)
    }

    @Test func clampsAboveBaseToOne() {
        #expect(PlayerMetrics(width: 3000).u == 1.0)
    }

    @Test func derivesUnitValuesAtFullScale() {
        let m = PlayerMetrics(width: 1920)
        #expect(m.padX == 80)
        #expect(m.chipHeight == 72)
        #expect(m.closeSize == 72)
        #expect(m.progressBottom == 148)
    }

    @Test func phoneSetIsSeventyPercent() {
        #expect(PlayerMetrics.phone.u == 0.7)
    }

    @Test func derivesScaledValuesAtPhoneScale() {
        // Confirms the transform is a plain linear `base * u`, not `u²` or similar.
        // `handleDiameter` (22u) and `trackHeight` (8u) stand in for the scaling check —
        // the scrubber/progress metrics stay u-scaled on phone. The chrome round-button
        // and transport sizes (`closeSize`, `transport*`) opt OUT on phone (fixed `phone*`
        // statics, like `chipHeight`), so they're no longer linear-scaling witnesses.
        let m = PlayerMetrics.phone   // u = 0.7
        #expect(abs(m.handleDiameter - 22 * 0.7) < 0.0001)
        #expect(abs(m.trackHeight - 8 * 0.7) < 0.0001)
    }

    @Test func phoneChromeLayoutHoldsAuthoredValues() {
        // The iPhone HUD's edge/row layout is authored at 1× (NOT u-scaled) — these used
        // to be scattered literals in `PlayerControlsView.phoneControls`. Values are the
        // compact-chrome set (`e8d4912`).
        #expect(PlayerMetrics.phonePadX == 26)
        #expect(PlayerMetrics.phoneTopBarTop == 22)
        #expect(PlayerMetrics.phoneTopBarGap == 14)
        #expect(PlayerMetrics.phoneTransportGap == 46)
        #expect(PlayerMetrics.phoneChipRowGap == 8)
        #expect(PlayerMetrics.phoneChipRowBottom == 20)
        #expect(PlayerMetrics.phoneProgressBottom == 64)
    }

    @Test func loadingRingTracesThePlayDisc() {
        // The veil's loading ring shares the centre play/pause disc's diameter so the
        // arc traces the disc's EXACT circumference and the two swap in place
        // (PlayerControlsView.showsCenterTransport / PlayerLoadingScrim). This locks
        // them together so a future tweak to the disc size carries the ring with it.
        // iPad: rides the big-screen `transportPlay` formula, at any window scale.
        let full = PlayerMetrics(width: 1920)
        #expect(full.scrimRing == full.transportPlay)
        let pad = PlayerMetrics(width: 1366)
        #expect(pad.scrimRing == pad.transportPlay)
        // iPhone: the fixed compact play-disc static.
        #expect(PlayerMetrics.phone.scrimRing == PlayerMetrics.phoneTransportPlay)
        // tvOS DOES show the centre disc (the full HUD keeps the transport up — see
        // PlayerControlsView.showsCenterTransport), so its ring tracks `transportPlay` too.
        #expect(PlayerMetrics.tv.scrimRing == PlayerMetrics.tv.transportPlay)
    }

    @Test func scrimCaptionIsBigScreenOnly() {
        // A landscape iPhone has no room for the veil's caption between the
        // center-pinned ring and the bottom scrubber (center + ring radius + gap +
        // two caption lines overshoots the scrubber band on every phone size), so
        // the phone shows the bare ring — the system phone-player idiom. Big
        // screens keep the caption.
        #expect(!PlayerMetrics.phone.scrimShowsCaption)
        #expect(PlayerMetrics(width: 1366).scrimShowsCaption)
        #expect(PlayerMetrics.tv.scrimShowsCaption)
    }

    @Test func scrubBarPlacementMatchesTheHudScrubber() {
        // The double-tap seek bar (`PlayerScrubBar`) and the full-HUD scrubber MUST pin to
        // the same screen spot — same horizontal inset, same bottom offset — or a seek
        // reads as a jump (the tvOS lesson). They share ONE source: `scrubberInsetX` /
        // `scrubberBottom`. This locks them together so a future tweak to one moves both.
        // iPhone: the fixed phone statics.
        #expect(PlayerMetrics.phone.scrubberInsetX == PlayerMetrics.phonePadX)
        #expect(PlayerMetrics.phone.scrubberBottom == PlayerMetrics.phoneProgressBottom)
        // iPad: the big-screen formulas (== padX / progressBottom).
        let pad = PlayerMetrics(width: 1920)
        #expect(pad.scrubberInsetX == pad.padX)
        #expect(pad.scrubberBottom == pad.progressBottom)
        // tvOS — the literal `PlayerScrubBar(metrics: .tv, …)` the reducer feeds (PlayerView).
        #expect(PlayerMetrics.tv.scrubberInsetX == PlayerMetrics.tv.padX)
        #expect(PlayerMetrics.tv.scrubberBottom == PlayerMetrics.tv.progressBottom)
    }
}
