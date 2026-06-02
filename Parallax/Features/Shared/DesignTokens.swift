import SwiftUI

// MARK: - Theme-adaptive color helper
//
// One greppable source for the design palette. `Color(light:dark:)` resolves the
// right value for the current appearance through a UIColor trait closure, so call
// sites never branch on colorScheme. Hex is 0xRRGGBB; alpha is separate so the
// handoff's rgba() tints port directly.
extension Color {
    init(light: UInt32, lightAlpha: Double = 1, dark: UInt32, darkAlpha: Double = 1) {
        self = Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let hex = isDark ? dark : light
            let alpha = isDark ? darkAlpha : lightAlpha
            return UIColor(
                red:   CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue:  CGFloat(hex & 0xFF) / 255,
                alpha: CGFloat(alpha)
            )
        })
    }
}
