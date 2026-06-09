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
        #expect(m.padX == 60)
        #expect(m.chipHeight == 54)
        #expect(m.closeSize == 58)
        #expect(m.progressBottomScrub == 168)
    }

    @Test func phoneSetIsNinetyTwoPercent() {
        #expect(PlayerMetrics.phone.u == 0.92)
    }

    @Test func derivesScaledValuesAtPhoneScale() {
        // Confirms the transform is a plain linear `base * u`, not `u²` or similar.
        let m = PlayerMetrics.phone   // u = 0.92
        #expect(abs(m.chipHeight - 54 * 0.92) < 0.0001)
        #expect(abs(m.trackHeightNormal - 8 * 0.92) < 0.0001)
    }
}
