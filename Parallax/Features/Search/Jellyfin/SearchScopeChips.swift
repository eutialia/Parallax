import SwiftUI
import ParallaxCore

/// One entry in the app's search-scope vocabulary.
///
/// `allOptions` is the SINGLE list of scopes-and-their-words, feeding both the iOS/iPadOS
/// segmented `Picker` (`JellyfinSearchView.scopeOptions`) and the tvOS chip row below, so the
/// two platforms' scope lists can't drift. Values rather than a shared `@ViewBuilder`, because
/// the two surfaces need different controls out of the same words: `Text().tag()` rows for the
/// Picker, focusable Buttons for the chips.
struct SearchScopeOption: Identifiable, Hashable {
    let scope: SearchScope
    let title: String

    var id: SearchScope { scope }

    static let allOptions: [SearchScopeOption] = [
        SearchScopeOption(scope: .all, title: "All"),
        SearchScopeOption(scope: .movies, title: "Movies"),
        SearchScopeOption(scope: .series, title: "Shows"),
        SearchScopeOption(scope: .episodes, title: "Episodes"),
    ]
}

/// The tvOS in-content search-scope chip row.
///
/// Deliberately NOT `.searchScopes`. The system scope bar renders in the search PRESENTATION
/// layer — chrome outside the app's own view tree — so it can never scroll away with the results
/// (on device it read as "always centered", pinned above content that moved under it) and the
/// focus engine treats it as system chrome rather than a stop in the results' focus order. This
/// row lives INSIDE the results scroll instead, exactly like `LibraryHeaderControls` does for the
/// library grid's Genre/Sort chips.
///
/// Value-driven (selection in, callback out) rather than owning the scope: the scope is the search
/// SCREEN's `@State` — the `.searchable` field, the view model, and this row all read the one
/// value — and the callback keeps writing to that single box even from a memoized parent (setting
/// `@State` goes through a stable storage box, not the captured struct).
///
/// tvOS-only by intent, but gated at the CALL SITE on `idiom == .tv` (not `#if os(tvOS)`), so the
/// tv-idiom previews render the same structure the device does. iPhone/iPad carry the segmented
/// `Picker` above the content instead — there's no focus engine there and nothing to scroll past.
struct SearchScopeChips: View {
    let selection: SearchScope
    let onSelect: (SearchScope) -> Void

    var body: some View {
        // No `GlassEffectContainer` — same reason `LibraryHeaderControls` skips it: on tvOS the
        // container re-renders native button glass in its own layer and desyncs from the system
        // focus lift.
        HStack(spacing: Space.s12) {
            ForEach(SearchScopeOption.allOptions) { option in
                chip(option)
            }
        }
        .frame(maxWidth: .infinity)
        // One container, named like the iOS Picker ("Search scope"), so VoiceOver announces what
        // the four chips are FOR before reading them — the Picker gets that from its title, which
        // a bare HStack of Buttons has no equivalent of. `.contain` keeps each chip its own stop.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search scope")
        .padding(.top, AppLayout.chipRowTopPadding)
        // Clear the first results row at 10-foot distance so the chips' focus lift can't collide
        // with row 1's. Shared with `LibraryHeaderControls` through the token — both rows sit above
        // a poster grid and must inset alike.
        .padding(.bottom, AppLayout.chipRowBottomClearance)
        // The chips sit centered, so they only cover the middle columns. The tvOS focus engine
        // searches straight UP from a focused tile, so from the outer columns there'd be no chip
        // in line and pressing Up would do nothing. `focusSection()` turns the row's full width
        // into ONE focus target that diverts to the nearest chip — Up from any column reaches it.
        .tvFocusSection()
    }

    /// One scope chip.
    ///
    /// `.glassProminent` for EVERY chip, selected or not, with only the tint changing — a scope bar
    /// has to show which of four chips is live, and the plain `.glass` style can't: its tint colours
    /// the LABEL, not the capsule, so `chipSelectedFill` (near-white) merely dimmed the selected
    /// chip's text a shade and the four capsules rendered identically (render-proven in the
    /// "Search scope chips" preview below — that was the first cut). Prominent fills the capsule
    /// with the tint and picks a contrasting label for it, which is the difference that reads at 10
    /// feet. `chipSelectedFill` is the same "active filter" fill the library header's Genre chip
    /// uses; `chipRestFill` is its translucent counterpart, so an unselected chip still reads as
    /// glass over the floor.
    ///
    /// The resting tint is `chipRestFill` and NOT the generic `selectionFill`/`fill` resting alphas:
    /// prominent glass composites its tint over a near-white backing on the LIGHT face, which ate
    /// both of them whole — 1.01:1 and 1.00:1 against the daylight floor, i.e. four invisible chips
    /// (the defect this token exists to fix; see its doc comment for the tuning sweep). Only the
    /// light alpha moved: `chipRestFill`'s dark face is byte-identical to what the chips rendered
    /// before, so the dark row is untouched.
    ///
    /// Never branch the STYLE on selection (`.glass` when off, `.glassProminent` when on): a
    /// `buttonStyle` swap puts the two states in different `_ConditionalContent` branches, which
    /// tears the Button down and drops tvOS focus mid-selection. One style, tint-only change —
    /// the same identity-stability rule `LibraryHeaderControls` records for its Genre menu.
    ///
    /// Not `.bordered`: on tvOS its platter AND label both take the tint, so under our monochrome
    /// `Color.label` the two collapse and the label goes invisible until focus inverts it.
    ///
    /// EVERY chip paints its own label; none is left bare for the style to color. `.glassProminent`
    /// draws a white label regardless of what its tint resolves to, so on the light face BOTH states
    /// went out white-on-near-white (render-proven: 10.5:1 for the selected chip only because it
    /// already overrode; 1.31:1 for the unselected ones, which is invisible text). The general
    /// "leave it bare so the style owns it" rule `LibraryHeaderControls` records applies to `.glass`,
    /// whose tint colors the label — not to this style, which colors the capsule.
    ///
    /// The colors are read off the enclosing Button's focus via `TVFocusReader` — the same mechanism
    /// the focus platters use, and legal here because it reads focus INSIDE one style rather than
    /// swapping styles. That reader is exactly what makes overriding the UNSELECTED label safe on
    /// tvOS: a focused control's platter goes opaque WHITE, so a bare `Color.label` would be
    /// white-on-white in focus (the reason that label used to be left alone) — the focused branch
    /// keeps the platter's own ink instead:
    /// - focused → `playerInk`, the theme-FIXED ink token for exactly this "content on a solid
    ///   white active surface" case. The tvOS focus platter is white in BOTH faces, so an adaptive
    ///   token would vanish on the light face.
    /// - selected, at rest → `buttonLabel`, `chipSelectedFill`'s counterpart: off-white on the light
    ///   face's graphite pill, ink on the dark face's white one, so the pair inverts with the theme.
    /// - unselected, at rest → `Color.label`, which inverts with the theme the same way over
    ///   `chipRestFill`: ink on the light face's gray capsule (9.3:1), white on the dark face's —
    ///   the latter being the exact white the style was already drawing, which is why the dark
    ///   render is unchanged.
    ///
    /// `isFocused` is always false off tvOS, so iOS/previews get the resting color unconditionally.
    private func chip(_ option: SearchScopeOption) -> some View {
        let isSelected = option.scope == selection
        return Button {
            onSelect(option.scope)
        } label: {
            TVFocusReader { focused in
                Text(option.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(focused ? Color.playerInk : (isSelected ? Color.buttonLabel : Color.label))
            }
        }
        .buttonStyle(.glassProminent)
        .tint(isSelected ? Color.chipSelectedFill : Color.chipRestFill)
        // The fill is the only "selected" signal on screen; VoiceOver needs it said out loud.
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The tvOS search screen's ONE scroll surface: the persistent scope-chip row above whatever the
/// current state renders beneath it.
///
/// Single instance by design. The chip row used to be rebuilt inside each state branch — inside the
/// results grid's own ScrollView when loaded, inside a plain VStack when empty or failed, inside the
/// skeleton's ScrollView while loading — so narrowing the scope to zero results tore the FOCUSED
/// chip out of the tree and the focus engine handed focus back to the system keyboard, stranding
/// the user in the exact state they needed the chips to escape. One surface at one position in the
/// view tree means the row keeps its identity (and its focus) while the content under it swaps.
///
/// It also owns the `contentMargins` for every state, so the skeleton→results swap can't shift: one
/// inset, applied once, instead of three hand-synced copies (`AppLayout.searchContentVMargin`).
///
/// tvOS-shaped, so the call site gates it on `idiom == .tv`: iPhone/iPad put their scope Picker in
/// the screen's chrome and must keep their status states OUT of a scroll view (see
/// `StatusStateView`, which sizes itself to the whole viewport).
struct TVSearchScopeSurface<Content: View>: View {
    let scope: SearchScope
    /// Hidden at idle only — matching iOS, whose Picker rides the same `hasActiveSearch` gate.
    let showsScopes: Bool
    /// Mirrors the iOS shell's `.scrollDisabled(isShowingSkeleton)` (`JellyfinSearchView.content`):
    /// only the skeleton locks scrolling, a loaded grid scrolls normally.
    let isShowingSkeleton: Bool
    let onSelectScope: (SearchScope) -> Void
    @ViewBuilder let content: Content

    @Environment(\.appIdiom) private var idiom

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if showsScopes {
                    SearchScopeChips(selection: scope, onSelect: onSelectScope)
                }
                content
            }
        }
        .scrollDisabled(isShowingSkeleton)
        // Overscan room INSIDE the clip so a focused chip's or tile's lift at the leading edge, the
        // top, or the bottom has room to grow — the title-safe-margin approach `LibraryGridView`
        // uses. Deliberately NOT `scrollClipDisabled()`: that fixed the sliced leading-edge shadow
        // by unclipping all four edges, which let scrolled rows paint up over the search chrome. If
        // a shadow still slices on device the remedy is a wider margin, never unclipping.
        .contentMargins(.horizontal, AppLayout.contentHMargin(idiom: idiom), for: .scrollContent)
        .contentMargins(.vertical, AppLayout.searchContentVMargin(idiom: idiom), for: .scrollContent)
    }
}

#if DEBUG
/// Chip-row parity: four scopes centered on the row's axis (red hairline), the selected one
/// filled with `chipSelectedFill` while the rest carry `chipRestFill`. Wrapped in
/// `.tint(Color.label)` to mirror `RootView`'s global tint. Half of a matched pair — the light
/// render below is the other half, and a tint change has to be judged on both.
#Preview("Search scope chips", traits: .fixedLayout(width: 900, height: 320)) {
    VStack(spacing: Space.s40) {
        SearchScopeChips(selection: .all, onSelect: { _ in })
        SearchScopeChips(selection: .episodes, onSelect: { _ in })
    }
    .padding(.horizontal, 48)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .center) {
        Rectangle().fill(Color.red.opacity(0.55)).frame(width: 1)
    }
    .background(Color.background)
    .tint(Color.label)
    .environment(\.colorScheme, .dark)
}

/// The SAME row on the light face — a permanent second render, because every earlier render of this
/// file pinned `.dark` and the resting tint's light face went out barely visible on the daylight
/// floor (a 9% graphite wash) without anyone seeing it. The two previews are a matched pair: any
/// change to a chip tint has to be judged on BOTH, and the bar on this one is that all four capsules
/// read as capsules against `Color.background` at 10 feet while staying obviously quieter than the
/// selected chip.
#Preview("Search scope chips · light", traits: .fixedLayout(width: 900, height: 320)) {
    VStack(spacing: Space.s40) {
        SearchScopeChips(selection: .all, onSelect: { _ in })
        SearchScopeChips(selection: .episodes, onSelect: { _ in })
    }
    .padding(.horizontal, 48)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .center) {
        Rectangle().fill(Color.red.opacity(0.55)).frame(width: 1)
    }
    .background(Color.background)
    .tint(Color.label)
    .environment(\.colorScheme, .light)
}

/// tv-idiom regression for the NO-RESULTS state under the persistent chip row. `StatusStateView`
/// sizes itself to the whole viewport (`containerRelativeFrame(.vertical)` + `ignoresSafeArea`),
/// and here it is a SIBLING below ~138pt of chips inside one scroll — this render is what proves
/// the block still reads as centered rather than shoved off the bottom. It is also the state the
/// whole surface exists for: a scope narrowed to nothing, with the chips still there to widen it.
#Preview("TV search — no results", traits: .fixedLayout(width: 1920, height: 1080)) {
    @Previewable @State var scope: SearchScope = .episodes
    TVSearchScopeSurface(scope: scope, showsScopes: true, isShowingSkeleton: false, onSelectScope: { scope = $0 }) {
        StatusStateView.searchNoResults
    }
    .background(Color.background)
    .environment(\.appIdiom, .tv)
    .environment(\.colorScheme, .dark)
    .tint(Color.label)
}

/// Same shape for the FAILURE state — the other branch that used to lose its chips, and the one
/// where switching scope re-runs the search. Its message wraps, so it also checks the taller block
/// against the chip row above it.
#Preview("TV search — failed", traits: .fixedLayout(width: 1920, height: 1080)) {
    @Previewable @State var scope: SearchScope = .all
    TVSearchScopeSurface(scope: scope, showsScopes: true, isShowingSkeleton: false, onSelectScope: { scope = $0 }) {
        StatusStateView.failure(
            "Couldn't search your library",
            message: "Parallax couldn't reach your servers."
        )
    }
    .background(Color.background)
    .environment(\.appIdiom, .tv)
    .environment(\.colorScheme, .dark)
    .tint(Color.label)
}
#endif
