import SwiftUI

extension View {
    /// The over-video control material shared by every HUD control — the Close/skip
    /// discs (`PlayerRoundButton`), the track chips (`PlayerGlassChip`), and the
    /// AirPlay/PiP pill (`PlayerSplitPill`): `.clear` interactive glass over a black
    /// 0.3 dim (Apple's media-controls guidance — `.regular`'s dark frost read as a
    /// flat tinted shape over footage; clear lets the video refract through and the
    /// dim keeps glyphs legible) plus a white hairline. One recipe in one place:
    /// these controls sit inches apart in the same HUD and must not drift in
    /// frost/dim/rim weight.
    ///
    /// `off` removes the material AT THE SOURCE (glass → `.identity`, dim and
    /// hairline → 0): opacity alone can't hide glass a `GlassEffectContainer` is
    /// rendering in its own layer, and an opaque platter can't cover the material's
    /// edge rim + outward shadow. Used by the focused disc and the vacated/platter
    /// chip. `hairline: nil` skips the stroke for callers that own a stateful one
    /// (the chip's platter/active rim).
    func playerGlassSurface(
        in shape: some InsettableShape, off: Bool = false, hairline: Double? = 0.20
    ) -> some View {
        self
            .glassEffect(off ? .identity : .clear.interactive(), in: shape)
            .background(.black.opacity(off ? 0 : 0.3), in: shape)
            .overlay {
                if let hairline {
                    shape.strokeBorder(.white.opacity(off ? 0 : hairline), lineWidth: 1)
                }
            }
    }
}
