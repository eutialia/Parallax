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

    /// The seek-flash dome ink (design `rgb(6,6,12)`); the gradient stops that
    /// shape the dome live with the flash itself.
    static let domeColor = Color(red: 6 / 255, green: 6 / 255, blue: 12 / 255)

    /// Stand-in "paused video frame" behind scrim previews. Previews only —
    /// shipped scrims always sit over real player output.
    static let previewBackdrop = Color(red: 0.05, green: 0.05, blue: 0.06)

    /// State dim factors: a cold start is heaviest (there's nothing to watch yet),
    /// a live-frame reload/stall lightest (the picture is still the subject),
    /// errors between. Paused matches the live-frame weight — the frozen frame
    /// stays the subject; the dim just marks it as held (see PlayerPausedOverlay).
    static let coldStartDim = 0.74
    static let liveFrameDim = 0.50
    static let pausedDim = 0.50
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
