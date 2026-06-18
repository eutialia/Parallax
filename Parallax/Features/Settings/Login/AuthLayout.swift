import SwiftUI

/// Shared layout constants for the logged-out connect surfaces (source picker, sign-in, Quick
/// Connect) so the picker's custom layout lines its brand mark up with the sliding bodies. The
/// Settings add-server forms use `SettingsFormScaffold` (top-aligned, settings width) instead; these
/// values are the connect flow's tighter, upper-third measure.
enum AuthLayout {
    /// Top inset as a fraction of the viewport height — lifts the card high in the viewport.
    static let topBias: CGFloat = 0.08

    /// Max content width for the connect surfaces. tvOS gets a much wider measure: its 10-foot text
    /// styles render ~1.5–2× the iOS size, so the iOS form width (444) crammed the rows into wrapping,
    /// oversized-looking lines.
    #if os(tvOS)
    static let maxContentWidth: CGFloat = 600
    #else
    static let maxContentWidth: CGFloat = 444
    #endif
}
