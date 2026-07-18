import SwiftUI

extension View {
    /// Paints the `BackgroundField` light-field behind a screen's content, edge to edge.
    ///
    /// Why each screen needs this rather than one floor behind the whole tab host: when an iPad
    /// window is elevated (multitasking split / slide-over / a scaled window), the system fills the
    /// navigation content region with its OWN backing, drawn ABOVE anything sitting behind the
    /// `TabView` — and in dark mode that backing LIFTS to a lighter gray (Apple's depth cue), which
    /// reads as the background changing color when you resize the window. A single floor behind the
    /// host is hidden under it. Painting our own floor IN the content beats that backing and,
    /// since the tokens ignore `userInterfaceLevel`, pins it to one constant appearance at every
    /// window size — so the chrome band and the scroll content never seam or shift.
    ///
    /// The field lives in the background layer, so it's pinned to the content region — content
    /// scrolls over stationary light, the field never travels with it.
    ///
    /// Applied per screen (root AND pushed destinations) since every navigation level gets its own
    /// content region. No-op cost on tvOS (no elevation), where it just restates the fixed floor.
    func screenFloor() -> some View {
        background { BackgroundField.style.ignoresSafeArea() }
    }
}
