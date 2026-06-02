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

// MARK: - Color tokens
//
// Named after Apple's semantic vocabulary (label / secondaryLabel / fill /
// separator / background) + app-specific roles (glass, button, chip, selection).
// Dark / Light(Matinee) values from the design handoff.
extension Color {
    static let background         = Color(light: 0xD0C8BA, dark: 0x07070B)
    static let backgroundElevated = Color(light: 0xDCD5C8, dark: 0x101016)
    static let surface            = Color(light: 0xFAF7F0, lightAlpha: 0.92, dark: 0x1A1A22)

    static let label              = Color(light: 0x221E17, dark: 0xFFFFFF)
    static let secondaryLabel     = Color(light: 0x2C261C, lightAlpha: 0.62, dark: 0xEBEBF5, darkAlpha: 0.62)
    static let tertiaryLabel      = Color(light: 0x2C261C, lightAlpha: 0.34, dark: 0xEBEBF5, darkAlpha: 0.34)
    static let separator          = Color(light: 0x281E0F, lightAlpha: 0.12, dark: 0xFFFFFF, darkAlpha: 0.10)

    static let fill               = Color(light: 0x4A3A24, lightAlpha: 0.12, dark: 0x787887, darkAlpha: 0.24)
    static let fillSecondary      = Color(light: 0x4A3A24, lightAlpha: 0.07, dark: 0x787887, darkAlpha: 0.16)

    static let glass              = Color(light: 0xF8F4ED, lightAlpha: 0.52, dark: 0x1C1C22, darkAlpha: 0.52)
    static let glassStrong        = Color(light: 0xFAF6EF, lightAlpha: 0.74, dark: 0x1E1E26, darkAlpha: 0.74)
    static let glassBorder        = Color(light: 0xFFFDF7, lightAlpha: 0.80, dark: 0xFFFFFF, darkAlpha: 0.14)
    static let glassHighlight     = Color(light: 0xFFFFFF, lightAlpha: 0.95, dark: 0xFFFFFF, darkAlpha: 0.22)

    static let buttonFill         = Color(light: 0x2A241D, dark: 0xFFFFFF)
    static let buttonLabel        = Color(light: 0xF7F2EA, dark: 0x0A0A0C)
    static let chipSelectedFill   = Color(light: 0x2A241D, dark: 0xFFFFFF, darkAlpha: 0.92)
    static let chipSelectedLabel  = Color(light: 0xF7F2EA, dark: 0x0A0A0C)
    static let selectionFill      = Color(light: 0x2D200F, lightAlpha: 0.09, dark: 0xFFFFFF, darkAlpha: 0.15)
}
