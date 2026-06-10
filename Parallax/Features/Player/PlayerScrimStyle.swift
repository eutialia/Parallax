import SwiftUI

/// Shared vocabulary for the player's transient overlay scrims (loading, seek,
/// error): the near-black dim wash they sit on and the one-shot rise their content
/// enters with. The scrims are deliberately monochrome white-on-dark — no brand
/// accent — matching the redesigned player chrome.
///
/// App target only: pure SwiftUI, no platform conditionals.
enum PlayerScrimStyle {
    /// The dim wash (design `rgba(4,4,8,0.46)`), modulated per state below.
    static let dimColor = Color(red: 4 / 255, green: 4 / 255, blue: 8 / 255)
    /// The wash's base alpha; multiplied by a state's dim factor.
    static let dimAlpha = 0.46

    /// State dim factors: buffering is heaviest (there's nothing to watch yet), an
    /// audio switch lightest (the paused picture is still the subject), errors between.
    static let bufferingDim = 0.74
    static let audioSwitchDim = 0.50
    static let errorDim = 0.62

    /// Entrance for centred scrim content: rise +10pt and fade in.
    static let rise = Animation.timingCurve(0.2, 0.85, 0.2, 1, duration: 0.42)
    static let riseOffset: CGFloat = 10

    /// Full-bleed dim layer at `dimAlpha × factor`. Never intercepts touches — the
    /// chrome underneath (scrubber, track menus) stays live while a scrim shows.
    static func dim(_ factor: Double) -> some View {
        dimColor.opacity(dimAlpha * factor)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}
