import Testing
import CoreGraphics
import ParallaxPlayback
@testable import Parallax

/// `SubtitleStyle.freetypeRelativeFontSize` is the ONE place the two subtitle paths'
/// sizes are related: VLC's freetype renderer draws an embedded SRT at
/// `videoOutputHeight / N`, and N has to land on the em the client renderer would have
/// drawn an external SRT at (`PlayerMetrics.subtitleFontSize × fontScale`) over the
/// aspect-fitted 16:9 video rect. These lock the arithmetic on all three device classes.
@Suite struct SubtitleStyleSizingTests {

    /// One device class's tuned metrics against the surface it plays on. A named type
    /// rather than a tuple so the class label rides into the failure message.
    struct SizingCase: Sendable, CustomTestStringConvertible {
        let metrics: PlayerMetrics
        let surface: CGSize
        let expected: Int
        let deviceClass: String
        var testDescription: String { deviceClass }
    }

    /// The surface is a landscape player; the video rect is the 16:9 fit inside it, so
    /// the phone (2.17:1) is height-limited and tvOS fills exactly.
    static let deviceCases: [SizingCase] = [
        // iPhone 17 Pro landscape: em 20, video rect 393 tall → 393/20 = 19.65.
        SizingCase(metrics: .phone, surface: CGSize(width: 852, height: 393),
                   expected: 20, deviceClass: "phone"),
        // tvOS: em 46, video rect 1080 tall → 1080/46 = 23.48.
        SizingCase(metrics: .tv, surface: CGSize(width: 1920, height: 1080),
                   expected: 23, deviceClass: "tv"),
        // 11" iPad landscape: u = 1194/1920 = 0.622, so subtitleFontSize floors at 20;
        // the 16:9 rect is 1194 × 9/16 = 671.6 tall → 671.6/20 = 33.58.
        SizingCase(metrics: PlayerMetrics(width: 1194), surface: CGSize(width: 1194, height: 834),
                   expected: 34, deviceClass: "pad"),
    ]

    @Test("the divisor tracks each device class's tuned cue size", arguments: deviceCases)
    func divisorPerDeviceClass(device: SizingCase) {
        let n = SubtitleStyle.standard.freetypeRelativeFontSize(
            surface: device.surface, metrics: device.metrics
        )
        #expect(n == device.expected)
    }

    /// The size control multiplies the em, and N is the height OVER the em — so doubling
    /// the size halves the divisor and halving it doubles the divisor (to the rounding).
    @Test("fontScale moves the divisor inversely", arguments: [
        (2.0, 10),    // em 40 → 393/40 = 9.83
        (0.5, 39),    // em 10 → 393/10 = 39.3
    ])
    func divisorInvertsFontScale(scale: Double, expected: Int) {
        let style = SubtitleStyle.standard.with { $0.fontScale = scale }
        let n = style.freetypeRelativeFontSize(
            surface: CGSize(width: 852, height: 393), metrics: .phone
        )
        #expect(n == expected)
    }

    /// A degenerate surface can't be allowed to ask freetype for a cue a quarter of the
    /// picture tall — and 0 would read as freetype's "Auto", i.e. its own 1/16th default.
    @Test func divisorHasAFloor() {
        let n = SubtitleStyle.standard.freetypeRelativeFontSize(
            surface: CGSize(width: 100, height: 50), metrics: .phone
        )
        #expect(n == SubtitleStyle.freetypeRelativeFontSizeFloor)
    }
}
