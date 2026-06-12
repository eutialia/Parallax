import SwiftUI

/// Launch-stage colors, adapted from the design handoff to the app's own
/// brand mark: the mono pencil + field values are sampled from the shipped
/// icon variants (Graphite / Paper), not the handoff's generic values. The
/// chromatic "working" pair has no icon counterpart — the icon is deliberately
/// monochrome — so those stay exactly as the handoff locked them.
struct LaunchPalette {
    /// Radial stage background, icon-derived; resolves toward `Color.background`'s
    /// family so the iris hand-off to the real screen floor reads seamless.
    /// The system launch screen paints this gradient's MID stop
    /// (`LaunchBackground.colorset` + `UILaunchScreen` in Config/Info.plist) so
    /// tap → first animation frame has no color seam — keep them in sync.
    let fieldGradient: Gradient
    /// Vertical center of the field's radial bloom, in unit space.
    let fieldCenterY: Double
    /// The icon's own pencil line — opening + merged-ring color.
    let pencil: UInt32
    /// Ghost ("second viewpoint") line opacity in the mono pose.
    let ghostOpacity: Double
    /// The working pair (handoff-locked; not icon-derived).
    let chromaMain: UInt32
    let chromaGhost: UInt32
    /// How the chromatic pair composites onto the field.
    let chromaBlend: GraphicsContext.BlendMode
    /// Brand halo behind the rings — light mode only (dark = plain rings, per
    /// spec). Stored pre-built: the stage draws at up to 120 Hz and gradient
    /// stops never change within a scheme.
    let haloGradient: Gradient?
    /// Focus-snap bloom at the merge — light mode only.
    let flashGradient: Gradient?

    static func current(for colorScheme: ColorScheme) -> LaunchPalette {
        colorScheme == .dark ? .dark : .light
    }

    /// Graphite icon: flat `#17171E` ground, `#E8E6EF` pencil.
    static let dark = LaunchPalette(
        fieldGradient: Gradient(stops: [
            .init(color: launchColor(0x17171E), location: 0),
            .init(color: launchColor(0x101016), location: 0.58),
            .init(color: launchColor(0x0B0B10), location: 1),
        ]),
        fieldCenterY: 0.42,
        pencil: 0xE8E6EF,
        ghostOpacity: 0.34,
        chromaMain: 0xC657D9,
        chromaGhost: 0x15B7EE,
        chromaBlend: .screen,
        haloGradient: nil,
        flashGradient: nil
    )

    /// Paper icon: warm paper radial (sampled center → corner), `#372C23` ink.
    static let light = LaunchPalette(
        fieldGradient: Gradient(stops: [
            .init(color: launchColor(0xDFD7C8), location: 0),
            .init(color: launchColor(0xD4CCBB), location: 0.6),
            .init(color: launchColor(0xC9BFAB), location: 1),
        ]),
        fieldCenterY: 0.36,
        pencil: 0x372C23,
        ghostOpacity: 0.30,
        chromaMain: 0xA038C4,
        chromaGhost: 0x0A7FB8,
        chromaBlend: .multiply,
        haloGradient: Gradient(stops: [
            .init(color: launchColor(0x463278, 0.16), location: 0),
            .init(color: launchColor(0x463278, 0), location: 0.7),
        ]),
        // Warm-ink bloom: full core, the handoff's 0.18 shoulder, clear edge.
        flashGradient: Gradient(stops: [
            .init(color: launchColor(0x372C23, 0.30), location: 0),
            .init(color: launchColor(0x372C23, 0.18), location: 0.3),
            .init(color: launchColor(0x372C23, 0), location: 0.6),
        ])
    )
}

/// `0xRRGGBB` → `Color` (sRGB). Local to the launch stage: the Canvas needs
/// raw hex lerping, which the `Color(light:dark:)` token initializer can't do.
func launchColor(_ hex: UInt32, _ alpha: Double = 1) -> Color {
    Color(
        red: Double((hex >> 16) & 0xFF) / 255,
        green: Double((hex >> 8) & 0xFF) / 255,
        blue: Double(hex & 0xFF) / 255
    )
    .opacity(alpha)
}

/// Per-channel lerp between two `0xRRGGBB` colors (u: 0 → a, 1 → b) — the
/// handoff's `lerpHex`, for the mono ↔ chromatic crossfade.
func launchLerp(_ a: UInt32, _ b: UInt32, _ u: Double) -> Color {
    func channel(_ shift: UInt32) -> Double {
        let ca = Double((a >> shift) & 0xFF)
        let cb = Double((b >> shift) & 0xFF)
        return (ca + (cb - ca) * u) / 255
    }
    return Color(red: channel(16), green: channel(8), blue: channel(0))
}
