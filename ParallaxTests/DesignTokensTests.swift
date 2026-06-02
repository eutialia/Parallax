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
}
