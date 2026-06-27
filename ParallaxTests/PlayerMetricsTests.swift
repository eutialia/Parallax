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
        // `closeSize` (72u) stands in for the scaling check — `chipHeight` opted out of
        // u-scaling on phone (it's the fixed `phoneChipHeight` compact value).
        let m = PlayerMetrics.phone   // u = 0.7
        #expect(abs(m.closeSize - 72 * 0.7) < 0.0001)
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
