import SwiftUI

/// The hero foreground column — the content skeleton both the Home carousel and the
/// movie/series detail header build: an optional eyebrow capsule, the title/logo, a subtitle
/// slot (overview/meta line on Home, the metadata badge row on detail), and an action row.
///
/// Centralizes the column's vertical rhythm (`Space.s12`), the action-row spacing/top inset, and
/// the tvOS focus grouping so the three call sites can't drift. It does NOT place itself in the
/// readable column or size the band — that's `heroForegroundPlacement` (applied by `HeroBand`)
/// and `heroBandFrame`. Content only; chrome lives one layer out.
struct HeroForeground<Subtitle: View, Actions: View>: View {
    /// Uppercase kicker (FEATURED / CONTINUE WATCHING …) rendered as a capsule — Home only; `nil`
    /// on detail headers, which lead with the title.
    let eyebrow: String?
    /// Title/logo treatment — built by the caller so each side picks its own `Scale`.
    let title: HeroTitle
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
            // One focus group so the focus engine prefers the action row as a unit (Play/Resume
            // default) over scattered geometry hits.
            .tvFocusSection()
        }
        // Cap the column so the title/actions never climb arbitrarily up the band; the fixed rows
        // hold their height and the subtitle absorbs the remainder.
        .frame(maxHeight: HeroMetrics.foregroundMaxHeight(idiom: idiom), alignment: .bottom)
    }
}

/// The Home hero's eyebrow capsule (renders a `HeroEyebrow` kind's text). Detail headers omit it
/// (they lead with the title), so this stays a tiny standalone view the Home call site feeds into
/// `HeroForeground.eyebrow`.
struct HeroEyebrowLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .tracking(1.5)
            .foregroundStyle(.white)
            .padding(.horizontal, Space.s12)
            .padding(.vertical, Space.s3)
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
            .frame(maxWidth: HeroMetrics.contentMaxWidth, alignment: .leading)
            .safeAreaPadding(.horizontal, HeroMetrics.foregroundHorizontalInset(idiom: idiom))
            .padding(.bottom, HeroMetrics.foregroundBottomInset(idiom: idiom))
    }
}
