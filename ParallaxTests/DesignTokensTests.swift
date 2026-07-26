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

    @Test(
        "Color(light:dark:) resolves the hex for the appearance in play",
        // (dark appearance?, expected value on every channel) — black in light, white in dark.
        arguments: [(true, 1.0), (false, 0.0)]
    )
    func resolvesPerAppearance(dark: Bool, expected: CGFloat) {
        let resolved = rgba(Color(light: 0x000000, dark: 0xFFFFFF), dark: dark)
        #expect(abs(resolved.r - expected) < 0.01)
        #expect(abs(resolved.g - expected) < 0.01)
        #expect(abs(resolved.b - expected) < 0.01)
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

    /// Both scales must stay strictly ordered by nesting depth: a panel contains cards, a card
    /// contains fields and tiles, so a corner radius that isn't monotonic reads as a mis-rounded
    /// child poking out of its parent. Asserted as ordering rather than as the handoff numbers —
    /// the numbers get retuned on purpose, the ordering never does, and `Space.sN`'s value is its
    /// own name anyway (`s16 == 16`), which makes an equality test a tautology.
    @Test("the radius and spacing scales stay strictly ordered")
    func metricScalesAreMonotonic() {
        #expect(Radius.panel > Radius.card)
        #expect(Radius.card > Radius.field)
        #expect(Radius.field > Radius.tile)
        #expect(Radius.tile > 0)
        let spacing = [Space.s8, Space.s16, Space.s22, Space.s40]
        #expect(spacing == spacing.sorted())
        #expect(Set(spacing).count == spacing.count)
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
