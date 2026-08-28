import SwiftUI

/// The hero foreground column — the content skeleton both the Home carousel and the
/// movie/series detail header build: an optional eyebrow capsule, the title/logo, a subtitle
/// slot (overview/meta line on Home, the metadata badge row on detail), and an action row.
///
/// Centralizes the column's vertical rhythm (`Space.s12`), the action-row spacing/top inset, and
/// the tvOS focus grouping so the three call sites can't drift. It does NOT place itself in the
/// readable column or size the band — that's `heroForegroundPlacement` (applied by `HeroBand`)
/// and `heroBandFrame`. Content only; chrome lives one layer out.
struct HeroForeground<Title: View, Subtitle: View, Actions: View>: View {
    /// Uppercase kicker (FEATURED / CONTINUE WATCHING …) rendered as a capsule — Home only; `nil`
    /// on detail headers, which lead with the title.
    let eyebrow: String?
    /// Title/logo treatment — built by the caller so each side picks its own `Scale`. Generic over
    /// the view rather than pinned to `HeroTitle` so `DetailLoadingSkeleton` can hang a stub in the
    /// same slot and inherit this column's rhythm instead of re-rolling it; the three
    /// shipping call sites still pass a `HeroTitle` and infer it.
    let title: Title
    /// Overview blurb / metadata line (Home) or the `DetailHeroMetadataRow` badge strip (detail).
    /// `@MainActor`: the slot builds view content on the main actor (and may touch main-actor VM
    /// state, e.g. `DetailMetadata`) — function types don't inherit the view's default isolation.
    @ViewBuilder var subtitle: @MainActor () -> Subtitle
    /// The action controls — Play pill plus the trailing circle buttons (Favorite, and the
    /// Watched / play-from-start variants). The row's `HStack`, spacing, top inset, and focus
    /// section are supplied here; the caller passes only the buttons. `@MainActor` for the same
    /// reason as `subtitle` — Series reads `vm.resumeEpisode` / `ItemPlayButtonLabel.shouldResumeSeries`.
    @ViewBuilder var actions: @MainActor () -> Actions

    @Environment(\.appIdiom) private var idiom
    /// Scope for the action row's default-focus pin — published into the row's environment so
    /// `PrimaryPlayButton` can claim default focus without the call sites threading anything.
    @Namespace private var actionRowNamespace

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            if let eyebrow {
                HeroEyebrowLabel(text: eyebrow)
                    .fixedSize(horizontal: false, vertical: true)
            }
            title
                .fixedSize(horizontal: false, vertical: true)
            // The ONLY flexible row: the overview slot shrinks its line count to fill whatever
            // height is left under `foregroundMaxHeight` (see `AdaptiveHeroOverview`). The metadata
            // badge row (detail) is short and just fits.
            subtitle()
            HStack(spacing: idiom == .tv ? Space.s18 : Space.s16) {
                actions()
            }
            // No `GlassEffectContainer` — it misrenders member glass on both platforms (nudged
            // glyphs off the discs on tvOS, desynced focus lift, gray-washed iOS frost; all
            // pixel-measured in the "Action row parity" preview). The native buttons never sit
            // close enough to want the blend anyway.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Space.s8)
            // The scope + `PrimaryPlayButton`'s environment-read `tvPrefersDefaultFocus` pin
            // Play as the DEFAULT-focus landing inside this row. Without the pin, a freshly
            // pushed detail screen resolves initial focus geometrically, and WHICH control wins
            // depends on the row's control count — movie's three controls (Play/Favorite/Watched)
            // landed Favorite while series's two landed Play. Default-focus evaluation only:
            // user-directed presses (Home's accepted chevron landing on Up) are untouched.
            // INVARIANT: the claimant must be STRUCTURALLY unconditional — an `if` (or a
            // `.disabled()`) around `PrimaryPlayButton` silently disarms this pin.
            .environment(\.heroActionRowFocusScope, actionRowNamespace)
            .tvFocusScope(actionRowNamespace)
            // One focus group so the row is a single traversal unit instead of scattered geometry
            // hits. On Home this section nests INSIDE a full-width band-level section
            // (`HomeHeroCarousel`'s `.tvFocusSection()`) that catches Up presses from shelf columns
            // past this row's intrinsic width and diverts them into this section. `focusSection()`
            // has no landing preference of its own, so DIRECTIONAL entry stays geometric-nearest
            // (the diverted Up press may land the chevron — evaluated on device and accepted);
            // only DEFAULT-focus resolution is pinned to Play, via the scope above.
            .tvFocusSection()
        }
        // Cap the column so the title/actions never climb arbitrarily up the band; the fixed rows
        // hold their height and the subtitle absorbs the remainder.
        .frame(maxHeight: HeroMetrics.foregroundMaxHeight(idiom: idiom), alignment: .bottom)
    }
}

extension EnvironmentValues {
    /// The enclosing hero action row's focus scope, when there is one. `PrimaryPlayButton` reads
    /// this to claim the row's default focus; nil (any host outside a hero action row) leaves the
    /// button inert, so standalone Play pills carry no stray focus preference.
    @Entry var heroActionRowFocusScope: Namespace.ID? = nil
}

/// The Home hero's eyebrow capsule (renders a `HeroEyebrow` kind's text). Detail headers omit it
/// (they lead with the title), so this stays a tiny standalone view the Home call site feeds into
/// `HeroForeground.eyebrow`.
struct HeroEyebrowLabel: View {
    let text: String

    @Environment(\.appIdiom) private var idiom

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .tracking(1.5)
            .foregroundStyle(.white)
            // `.caption` auto-ramps 12→25pt on tvOS; the capsule padding ramps with it or the
            // stroke crowds the text.
            .padding(.horizontal, idiom == .tv ? Space.s18 : Space.s12)
            .padding(.vertical, idiom == .tv ? Space.s8 : Space.s3)
            .background(.black.opacity(0.5), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
    }
}

extension View {
    /// Places a hero foreground column in the readable region: capped width, leading-aligned,
    /// horizontal safe-area inset + bottom inset per idiom. Applied by `HeroBand` to its
    /// `foreground` slot so the Home carousel and the detail header inset identically — the one
    /// source for the geometry the two used to re-roll (and where Home double-applied the width).
    func heroForegroundPlacement(idiom: AppIdiom) -> some View {
        self
            .frame(maxWidth: HeroMetrics.contentMaxWidth(idiom: idiom), alignment: .leading)
            .safeAreaPadding(.horizontal, HeroMetrics.foregroundHorizontalInset(idiom: idiom))
            .padding(.bottom, HeroMetrics.foregroundBottomInset(idiom: idiom))
    }
}
