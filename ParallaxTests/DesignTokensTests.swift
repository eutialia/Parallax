import Testing
import SwiftUI
import UIKit
@testable import Parallax

@MainActor
struct DesignTokensTests {
    /// Resolve a SwiftUI Color's RGBA for a given appearance via UIKit traits.
    private func rgba(_ color: Color, dark: Bool) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let style: UIUserInterfaceStyle = dark ? .dark : .light
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }

    @Test("Color(light:dark:) resolves the dark hex in dark appearance")
    func resolvesDark() {
        let c = Color(light: 0x000000, dark: 0xFFFFFF)
        let d = rgba(c, dark: true)
        #expect(abs(d.r - 1) < 0.01 && abs(d.g - 1) < 0.01 && abs(d.b - 1) < 0.01)
    }

    @Test("Color(light:dark:) resolves the light hex in light appearance")
    func resolvesLight() {
        let c = Color(light: 0x000000, dark: 0xFFFFFF)
        let l = rgba(c, dark: false)
        #expect(l.r < 0.01 && l.g < 0.01 && l.b < 0.01)
    }

    @Test("alpha is applied per-appearance")
    func appliesAlpha() {
        let c = Color(light: 0x000000, lightAlpha: 0.5, dark: 0xFFFFFF, darkAlpha: 0.25)
        #expect(abs(rgba(c, dark: false).a - 0.5) < 0.01)
        #expect(abs(rgba(c, dark: true).a - 0.25) < 0.01)
    }

    @Test("background token matches the dark hex #16161C")
    func backgroundDark() {
        let d = rgba(.background, dark: true)
        #expect(abs(d.r - 0x16/255.0) < 0.01 && abs(d.g - 0x16/255.0) < 0.01 && abs(d.b - 0x1C/255.0) < 0.01)
    }

    @Test("buttonFill is white in dark, graphite ink in light")
    func buttonFillFlips() {
        #expect(rgba(.buttonFill, dark: true).r > 0.99)          // #FFFFFF
        let l = rgba(.buttonFill, dark: false)
        #expect(abs(l.r - 0x22/255.0) < 0.01 && abs(l.b - 0x2A/255.0) < 0.01)  // #22222A graphite ink
    }

    @Test("radius + spacing scales hold the handoff values")
    func metricScales() {
        #expect(Radius.panel == 24 && Radius.card == 18 && Radius.field == 14 && Radius.tile == 12)
        #expect(Space.s8 == 8 && Space.s16 == 16 && Space.s22 == 22 && Space.s40 == 40)
    }

    @Test("chipSelectedFill stays translucent so selected chips read as glass, not flat paint")
    func chipSelectedFillIsTranslucent() {
        // At the old 0.92 the tint was effectively opaque — the "selected" chip read as a
        // solid platter, which on tvOS is the FOCUSED look. Keep it clearly translucent
        // (glass shows through) but strong enough for ink/cream label contrast.
        for dark in [true, false] {
            let a = rgba(.chipSelectedFill, dark: dark).a
            #expect(a <= 0.9 && a >= 0.6)
        }
    }
}
