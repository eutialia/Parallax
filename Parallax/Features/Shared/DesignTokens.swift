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
            return UIColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

private extension UIColor {
    /// Solid (or alpha-tinted) UIColor from a `0xRRGGBB` literal.
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red:   CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue:  CGFloat(hex & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    }
}

// MARK: - Color tokens
//
// Named after Apple's semantic vocabulary (label / secondaryLabel / fill /
// separator / background) + app-specific roles (glass, button, chip, selection).
// Dark / Light(Matinee) values from the design handoff.
// Always reference these qualified — `Color.fill` / `Color.background` / `Color.separator`;
// unqualified `.fill` / `.background` / `.separator` in a modifier resolve to SwiftUI's
// built-in ShapeStyle, not these tokens.
extension Color {
    /// Single screen floor — one FIXED value per appearance, deliberately constant across window
    /// size. Light = Matinee paper; dark = a deep blue-gray that tames vibrant poster artwork (true
    /// `#000` makes it bloom), kept just below `surface` so cards still read above it.
    ///
    /// We intentionally do NOT use a system background here: `systemBackground` / `secondarySystem…`
    /// lift to a lighter value when the scene is "elevated" (iPad multitasking / scaled window /
    /// modal — Apple's dark-mode depth cue), which reads as the background changing color when you
    /// resize the window. A flat custom color ignores `userInterfaceLevel`, and `screenFloor()`
    /// paints it OVER the system's own lifting content backing — so the floor stays put at every
    /// window size. (Light has no lift to defeat; that's a dark-mode-only mechanism.)
    static let background = Color(light: 0xD0C8BA, dark: 0x16161C)
    static let surface            = Color(light: 0xFAF7F0, lightAlpha: 0.92, dark: 0x1A1A22)  // dark tile opaque, light 0.92 — per handoff

    static let label              = Color(light: 0x221E17, dark: 0xFFFFFF)
    // Light alphas raised to clear WCAG AA against the BINDING backplate (the Color.fill settings
    // pill, ~192/183/168 — darker than the screen floor). secondaryLabel carries body/caption text →
    // 4.5:1 (0.80 → 4.92:1 on the pill); tertiaryLabel is the non-text glyph/placeholder tier → 3:1
    // (light 0.60 → 3.13:1, dark 0.45 → 3.60:1). The old 0.62/0.34 measured 3.27:1 / 1.82:1 — below
    // floor. Dark secondary already cleared (5.42:1) so it stays.
    static let secondaryLabel     = Color(light: 0x2C261C, lightAlpha: 0.80, dark: 0xEBEBF5, darkAlpha: 0.62)
    static let tertiaryLabel      = Color(light: 0x2C261C, lightAlpha: 0.60, dark: 0xEBEBF5, darkAlpha: 0.45)
    static let separator          = Color(light: 0x281E0F, lightAlpha: 0.12, dark: 0xFFFFFF, darkAlpha: 0.10)

    static let fill               = Color(light: 0x4A3A24, lightAlpha: 0.12, dark: 0x787887, darkAlpha: 0.24)
    static let fillSecondary      = Color(light: 0x4A3A24, lightAlpha: 0.07, dark: 0x787887, darkAlpha: 0.16)

    static let glass              = Color(light: 0xF8F4ED, lightAlpha: 0.52, dark: 0x1C1C22, darkAlpha: 0.52)
    static let glassBorder        = Color(light: 0xFFFDF7, lightAlpha: 0.80, dark: 0xFFFFFF, darkAlpha: 0.14)

    /// Hero/detail circular glass actions (Favorite, Watched, …). Fixed dark frosted
    /// chrome over photography — not theme-adaptive, so bright artwork and Matinee mode
    /// don't wash the control out or flip it to the light-glass variant.
    static let heroGlass          = Color(red: 0.08, green: 0.08, blue: 0.10).opacity(0.62)
    static let heroGlassBorder    = Color.white.opacity(0.28)

    /// Dark "ink" for glyphs/labels on the player's solid-white active surfaces (active
    /// chip, primary play button). Fixed (not theme-adaptive) on purpose, like `heroGlass`:
    /// the player is pinned `.dark` and paints explicit white/ink rather than the adaptive
    /// label tokens, so this stays `#0a0a0c` regardless of appearance. Mirrors the dark
    /// value of `buttonLabel`; kept as its own named token so the
    /// player never depends on an adaptive token resolving dark.
    static let playerInk          = Color(red: 10 / 255, green: 10 / 255, blue: 12 / 255)
    /// Player track-menu SELECTED-row fill — theme-FIXED (white 0.15), pinned like `playerInk` so a
    /// paper ancestor can never tint the selection over video. Equals `selectionFill`'s dark face.
    static let playerTrackSelectionFill = Color.white.opacity(0.15)
    /// Player track-menu attribute-BADGE fill — theme-FIXED graphite (equals `fill`'s dark face), so
    /// the badge chip reads the same over video regardless of the app's light/dark theme.
    static let playerTrackBadgeFill = Color(red: 120 / 255, green: 120 / 255, blue: 135 / 255).opacity(0.24)

    // Bright pill in dark mode (white fill / ink label), dark pill in light mode
    // (espresso fill / cream label) — used everywhere including over hero photography.
    static let buttonFill         = Color(light: 0x2A241D, dark: 0xFFFFFF)
    static let buttonLabel        = Color(light: 0xF7F2EA, dark: 0x0A0A0C)
    // The hero/detail Play pill has NO tokens here on purpose: it is theme-FIXED white + `playerInk`
    // in both themes (owner directive 2026-07-14 — it rides artwork and must not flip with the app
    // theme). See PrimaryPlayButton.swift.
    /// Selected-chip glass tint (the library header chips' `.tint` when a genre is
    /// applied). Translucent on purpose: at the old 0.92 the tint was effectively opaque,
    /// so the "glass" chip read as flat paint — and on tvOS a solid white chip is the
    /// system's FOCUSED look, which made selection ambiguous. The native `.glass` style
    /// owns the label color against it.
    static let chipSelectedFill   = Color(light: 0x2A241D, lightAlpha: 0.88, dark: 0xFFFFFF, darkAlpha: 0.78)
    static let selectionFill      = Color(light: 0x2D200F, lightAlpha: 0.09, dark: 0xFFFFFF, darkAlpha: 0.15)

    /// Status "active" green — the server LED (`--ok #3DA45A`). The one sanctioned non-mono color
    /// besides destructive red; it marks state, not brand, so the No-Accent rule still holds.
    static let ok                 = Color(light: 0x3DA45A, dark: 0x3DA45A)

    /// Destructive action red — Clear / Remove Server (handoff `--destructive #D8513E`). A warm red
    /// tuned to the Matinee palette rather than the cooler system red; the dark face brightens a touch
    /// so it clears contrast on the graphite floor. The sanctioned destructive color across Settings.
    static let destructive        = Color(light: 0xD8513E, dark: 0xE0604D)

    /// The loading/missing artwork field behind every poster and thumbnail. Two-faced so it tracks
    /// the palette: a recessed warm-stone block on Paper, a lifted graphite block at night — never a
    /// fixed dark gray (which read as a hole punched in the light Matinee floor).
    static let artworkPlaceholder = Color(light: 0xC2BAAC, dark: 0x26262C)
}

// MARK: - Metric tokens (radii, spacing)
//
// "native+" call: radii are custom (the concentric system is the brand "feel"
// lever); native List/Form keep their own system insets; typography is native
// Dynamic Type (added per-screen in later phases). Content insets land in P2,
// replacing AppLayout.contentHMargin (kept as one source until then).
enum Radius {
    static let panel: CGFloat = 24    // sidebar, large bars, modals
    static let card: CGFloat = 18     // cards, list groups, info cards
    static let field: CGFloat = 14    // text fields, form buttons
    static let tile: CGFloat = 12     // posters, thumbs, small tiles
    static let navItem: CGFloat = 12  // sidebar/tab item pills (panel − 12 inset)
    static let chip: CGFloat = 10     // the library-banner type-glyph chip
    static let badge: CGFloat = 7     // 4K/HDR/CC metadata badges (per handoff)
}

/// Hero / detail action row (Play pill + circle buttons). The pill height and circle diameter
/// are matched so the row aligns; sizes per the handoff (iPhone 50 / iPad 52 / Apple TV 62).
enum ActionRow {
    static func controlHeight(_ idiom: AppIdiom) -> CGFloat {
        #if os(tvOS)
        62
        #else
        idiom == .regular ? 52 : 50
        #endif
    }
    static let gap: CGFloat = Space.s16
}

/// Continue Watching / Next Up horizontal shelves (2:3 poster tiles).
enum HomeShelf {
    static let tileWidth: CGFloat = 172
    /// Jellyfin thumb width for @3x at `tileWidth` (avoids soft upscaling).
    static let imageMaxWidth: Int = 520
    /// Height the frosted blur feathers up from the caption into the poster (TV-style).
    static let footerBlurFeatherBleed: CGFloat = 56
    /// Darkening under the caption for text legibility on bright artwork.
    static let footerScrimOpacity: Double = 0.55
    /// Caption/progress insets inside the frosted footer — shared by `MediaTile` and the
    /// `GlassSurface` preview tile so the two can't drift apart.
    static let footerCaptionInsetX: CGFloat = 8
    static let footerCaptionInsetBottom: CGFloat = 7
}

/// Series detail episode shelves (16:9 landscape — matches Jellyfin episode primary).
enum SeriesShelf {
    static let episodeTileWidth: CGFloat = 240
    /// Jellyfin thumb width for @3x at `episodeTileWidth` (avoids soft upscaling).
    static let imageMaxWidth: Int = 720
}

enum Space {
    static let s3: CGFloat = 3
    static let s8: CGFloat = 8
    static let s12: CGFloat = 12
    static let s14: CGFloat = 14
    static let s16: CGFloat = 16
    static let s18: CGFloat = 18
    static let s22: CGFloat = 22
    static let s26: CGFloat = 26
    static let s30: CGFloat = 30
    static let s40: CGFloat = 40
    static let s60: CGFloat = 60
}

extension Animation {
    /// The house "organic settle" spring for user-initiated reveals and snaps (hero carousel
    /// page settle, detail overview expand). One token so the settle feel can't drift between
    /// surfaces; call sites keep their own Reduce-Motion gating.
    static let organicSettle = Animation.spring(response: 0.4, dampingFraction: 0.86)
}
