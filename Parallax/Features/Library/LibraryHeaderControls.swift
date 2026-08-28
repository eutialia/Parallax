import SwiftUI
import ParallaxCore

/// Capsule metrics for the ONE placeholder the live header still draws itself: the Genre slot while
/// genres are in flight (`genreSlot` below). It's a hand-sized stand-in for a control that doesn't
/// exist yet — the genre list decides the Menu's label, so there is nothing to measure — and it's
/// deliberately the only one left. `LibraryHeaderControlsSkeleton` no longer copies these: it
/// renders THIS view redacted, so the first-load row is the real control's footprint by
/// construction. (A `sortWidth` sibling used to guess the Sort chip too; it's gone with the copies.)
enum LibraryHeaderChip {
    static let height: CGFloat = AppLayout.tvControlHeight
    static let genreWidth: CGFloat = 140
}

/// The tvOS in-content Genre + Sort control row.
///
/// Value-driven (plain values in, callbacks out) rather than taking a view model, because the two
/// screens that show it own their sort state differently: a library grid has ONE
/// `LibraryGridViewModel`, while the Favorites wall has one per server and a coordinator that fans
/// a single sort choice out to all of them. A shared component that reached into a view model
/// could only serve the first.
///
/// tvOS-only by construction: iPhone and iPad carry the same controls in the nav bar via
/// `LibrarySortMenuButton`. This row lives INSIDE the scroll content so the focus engine can
/// scroll back up to it — a pinned header sits outside that scroll and can't be refocused.
struct LibraryHeaderControls: View {
    let sortField: ItemSort.Field
    let sortDirection: ItemSort.Direction
    let selectedGenre: String?
    let availableGenres: [String]
    /// Holds the Genre slot open with a skeleton capsule while genres are still in flight, so the
    /// grid below doesn't shift when they land.
    let isLoadingGenres: Bool
    let onSelectField: (ItemSort.Field) -> Void
    let onSelectDirection: (ItemSort.Direction) -> Void
    let onSelectGenre: (String?) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Read, not just inherited: a redacted header swaps each live chip for a flat stand-in
    /// (`chipOrStandIn`). See `LibraryHeaderControlsSkeleton`.
    @Environment(\.redactionReasons) private var redactionReasons

    var body: some View {
        // No `GlassEffectContainer` here: this row only renders on tvOS, where the container
        // re-renders the native button glass in its own layer — glyphs drift off the discs and the
        // glass desyncs from the system focus lift (pixel-measured in the "Action row parity"
        // preview).
        let hasGenreSlot = isLoadingGenres || !availableGenres.isEmpty
        // Split the row into two equal halves so the pair is symmetric about the screen's center
        // axis: Genre hugs the trailing edge of the left half, Sort the leading edge of the right
        // half, so the gap between them stays centered however their content-sized widths differ.
        // With no genres the left half collapses to zero width and Sort centers across the full
        // row — a lone control reads best centered, not pinned off-axis.
        HStack(spacing: hasGenreSlot ? Space.s12 : 0) {
            genreSlot
                .frame(maxWidth: hasGenreSlot ? .infinity : 0, alignment: .trailing)
            chipOrStandIn(sortMenu)
                .frame(maxWidth: .infinity, alignment: hasGenreSlot ? .leading : .center)
        }
        .padding(.top, AppLayout.chipRowTopPadding)
        // Clear the first poster row at 10-foot distance: 8pt crowded the chips against the grid and
        // let their focus lift collide with row 1's. The token is what the loading skeleton below
        // and the search screen's chip row read too, so the skeleton→real swap stays shift-free.
        .padding(.bottom, AppLayout.chipRowBottomClearance)
        // The two chips sit just inside the center axis, so they only cover the middle columns. The
        // tvOS focus engine searches straight UP from the focused poster, so from the outer columns
        // there's no chip in line and pressing Up does nothing. `focusSection()` turns the row's
        // full width into one focus target that diverts to the nearest chip — Up from ANY column
        // now reaches Genre/Sort. (Apple's tvOS catalog sample applies it for this exact case.)
        .tvFocusSection()
        .animation(reduceMotion ? nil : .smooth, value: isLoadingGenres)
    }

    /// The header's left slot: the Genre menu once genres load, a skeleton capsule while they're
    /// still in flight, or nothing when there are no genres (its equal-width half then collapses
    /// and Sort centers — see `body`).
    @ViewBuilder
    private var genreSlot: some View {
        if isLoadingGenres {
            Capsule().fill(Color.fill).frame(width: LibraryHeaderChip.genreWidth, height: LibraryHeaderChip.height)
        } else if !availableGenres.isEmpty {
            chipOrStandIn(genreMenu)
        }
    }

    /// A chip as the header draws it, or — under `.placeholder` redaction — as the skeleton does:
    /// the real Menu `.hidden()` with a flat capsule painted over its layout (`skeletonStandIn`).
    ///
    /// Redaction alone isn't enough here. It masks the label's glyphs but leaves the native
    /// `.glass` capsule ON, and `skeletonShimmer()` masks its sweep with a SECOND copy of the
    /// content — so the glass composited twice and the placeholder read as a dimmed live control
    /// instead of the flat bar every other skeleton draws. The stand-in keeps the win that made the
    /// skeleton render the real header in the first place (the hidden Menu still sizes the slot)
    /// and drops the material.
    @ViewBuilder
    private func chipOrStandIn(_ chip: some View) -> some View {
        if redactionReasons.contains(.placeholder) {
            chip.skeletonStandIn(in: Capsule())
        } else {
            chip
        }
    }

    /// Shares `libraryHeaderMenu` with Sort so the two chips are styled identically; a selected
    /// genre flips the resting monochrome tint to the filled `chipSelectedFill`.
    private var genreMenu: some View {
        libraryHeaderMenu(
            title: selectedGenre ?? "Genre",
            systemImage: "theatermasks",
            activeTint: selectedGenre != nil ? Color.chipSelectedFill : nil,
            accessibilityLabel: "Genre"
        ) {
            // Single-select genre filter, collapsed from a scrolling chip bar into one menu: the
            // inline `Picker` gives each genre the system's leading checkmark, "All Genres" clears.
            Picker("Genre", selection: Binding(get: { selectedGenre }, set: onSelectGenre)) {
                Text("All Genres").tag(String?.none)
                ForEach(availableGenres, id: \.self) { genre in
                    Text(genre).tag(String?.some(genre))
                }
            }
            .pickerStyle(.inline)
        }
    }

    /// No `activeTint`: Sort has no selected state, so it rests on the same monochrome
    /// `Color.label` tint as an unselected Genre.
    private var sortMenu: some View {
        libraryHeaderMenu(
            title: "Sort",
            systemImage: "arrow.up.arrow.down",
            accessibilityLabel: "Sort"
        ) {
            // Same human-language direction labels as the iOS bridged menu (one vocabulary —
            // `LibrarySortVocabulary`), but as an inline picker: the tile row is a touch-menu
            // affordance the tvOS focus engine doesn't render.
            Picker("Order", selection: Binding(get: { sortDirection }, set: onSelectDirection)) {
                ForEach(LibrarySortVocabulary.directionOptions(for: sortField), id: \.direction) { option in
                    Label(option.title, systemImage: option.icon).tag(option.direction)
                }
            }
            .pickerStyle(.inline)
            Picker("Sort By", selection: Binding(get: { sortField }, set: onSelectField)) {
                ForEach(ItemSort.Field.allCases, id: \.self) { field in
                    Text(LibrarySortVocabulary.label(for: field)).tag(field)
                }
            }
            .pickerStyle(.inline)
        }
    }
}

/// The tvOS header's loading skeleton: the REAL `LibraryHeaderControls`, fed placeholder inputs and
/// redacted. The row's height, its symmetry about the center axis and its top/bottom padding are
/// then the shipping control's by construction — where the two hand-guessed capsules it replaces
/// (140 × 64 and 110 × 64) only approximated a native `.glass` Menu, which sizes itself from its
/// label and its platform's type ramp.
///
/// `isLoadingGenres: true` is what the grid itself passes before the genre list lands, so the Genre
/// slot stays RESERVED here instead of collapsing to width 0 (the `!isLoadingGenres &&
/// availableGenres.isEmpty` branch) — the skeleton shows exactly what the loaded header shows while
/// its genres are still in flight, and the swap moves nothing.
///
/// `.redacted(reason: .placeholder)` is the SIGNAL, not the paint: `LibraryHeaderControls` reads it
/// and swaps each chip for a flat capsule over the hidden real Menu (`chipOrStandIn`), so the bar
/// carries the shipping control's frame with none of its glass.
///
/// `.disabled(true)` is load-bearing on tvOS. A placeholder that takes focus is a bug (Select opens
/// a menu of nothing), and disabled controls are skipped by the focus engine — the one place its
/// documented tvOS anti-pattern status is exactly what we want. The hidden Menu inside the stand-in
/// can't take focus either ("Hidden views are invisible and can't receive or respond to
/// interactions" — `View.hidden()`; `UIFocusDebugger.checkFocusability` lists `isHidden` among its
/// blockers), so the two are belt and braces. No `.allowsHitTesting(false)`: `.disabled` already
/// blocks activation, and the focus-engine reference flags that modifier as unreliable on tvOS.
///
/// The row's METRIC comes from the hidden real control, so it tracks whatever the native Menu sizes
/// itself to. Certifying that on the tvOS type ramp needs a render on a tvOS destination — the
/// parity preview below reads the iOS ramp when Xcode's destination is a simulator iPhone.
struct LibraryHeaderControlsSkeleton: View {
    var body: some View {
        LibraryHeaderControls(
            sortField: ItemSort.defaultForLibrary.field,
            sortDirection: ItemSort.defaultForLibrary.direction,
            selectedGenre: nil,
            availableGenres: [],
            isLoadingGenres: true,
            onSelectField: { _ in },
            onSelectDirection: { _ in },
            onSelectGenre: { _ in }
        )
        .redacted(reason: .placeholder)
        .disabled(true)
    }
}

/// Shared label for the tvOS header menus (Genre, Sort) so the two read identically.
/// Bare — the enclosing Menu wears the native `.glass` style, which owns the capsule,
/// metrics, and label color: the label rests as `Color.label` over translucent glass
/// (legible), and the focused platter brightens without recoloring it. A forced
/// `foregroundStyle` would fight that, so leave it off. Selection shows via the menu's tint.
private func libraryHeaderChipLabel(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
        .labelStyle(.titleAndIcon)
        .font(.subheadline.weight(.medium))
}

/// Shared builder for the tvOS in-content header menus (Genre + Sort) so the pair is styled
/// identically. Both wear the native `.glass` style — translucent Liquid Glass at rest,
/// brightening on focus — with a `Color.label` resting tint (the value `RootView` pins
/// app-wide), so the label reads legibly over the frosted capsule. A header passes a non-nil
/// `activeTint` (Genre's `chipSelectedFill`) only to flip to the filled "active filter" look.
///
/// NOT `.bordered`: on tvOS its resting platter takes the tint AND it draws the label in that
/// same tint, so under our monochrome `Color.label` the two collapse to one color and the
/// label is invisible until focus inverts it. `.glass` keeps the label and capsule distinct.
///
/// The resting tint is set EXPLICITLY, not left to inherit: Genre used to clear it with
/// `.tint(nil)`, which reset to the system accent and rendered a visibly different color
/// from Sort (which inherited `Color.label`) — the asymmetry this fixes. Passing the tint
/// unconditionally also keeps the modifier identity stable, so toggling a genre never tears
/// down the Menu and drops tvOS focus.
private func libraryHeaderMenu<Content: View>(
    title: String,
    systemImage: String,
    activeTint: Color? = nil,
    accessibilityLabel: String,
    @ViewBuilder content: () -> Content
) -> some View {
    Menu {
        content()
    } label: {
        libraryHeaderChipLabel(title, systemImage: systemImage)
    }
    .buttonStyle(.glass)
    .tint(activeTint ?? Color.label)
    .accessibilityLabel(accessibilityLabel)
}

#if DEBUG
/// Genre ⇄ Sort header parity + center-axis symmetry. The row splits into two equal halves —
/// Genre trailing-aligned in the left, Sort leading-aligned in the right — so the gap between
/// the pair stays centered on the axis (red hairline) however their content widths differ.
/// Both share the monochrome `Color.label` resting tint; Genre flips to `chipSelectedFill`
/// when a genre is active (second row). The third row is the no-genre case: Sort centers
/// alone on the same axis. Wrapped in `.tint(Color.label)` to mirror RootView's global tint.
#Preview("Header parity + axis", traits: .fixedLayout(width: 900, height: 470)) {
    VStack(spacing: Space.s40) {
        HStack(spacing: Space.s12) {
            libraryHeaderMenu(title: "Genre", systemImage: "theatermasks", accessibilityLabel: "Genre") { Text("Genres") }
                .frame(maxWidth: .infinity, alignment: .trailing)
            libraryHeaderMenu(title: "Sort", systemImage: "arrow.up.arrow.down", accessibilityLabel: "Sort") { Text("Sort") }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        HStack(spacing: Space.s12) {
            libraryHeaderMenu(title: "Action", systemImage: "theatermasks", activeTint: Color.chipSelectedFill, accessibilityLabel: "Genre") { Text("Genres") }
                .frame(maxWidth: .infinity, alignment: .trailing)
            libraryHeaderMenu(title: "Sort", systemImage: "arrow.up.arrow.down", accessibilityLabel: "Sort") { Text("Sort") }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        libraryHeaderMenu(title: "Sort", systemImage: "arrow.up.arrow.down", accessibilityLabel: "Sort") { Text("Sort") }
            .frame(maxWidth: .infinity, alignment: .center)
    }
    .padding(.horizontal, 48)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .center) {
        Rectangle().fill(Color.red.opacity(0.55)).frame(width: 1)
    }
    .background(Color.background)
    .tint(Color.label)
}

/// Skeleton ↔ live header parity, three rows: the redacted placeholder, the live control once
/// genres have landed, and a chip-metric PROBE.
///
/// The probe is the load-bearing part. `.glass` over black is invisible to a luminance scan, so each
/// probe paints the SAME Sort menu on `Color.fill` — the fill takes the control's own frame, which
/// the ruler can then read. Live (left) and redacted + disabled (right) must measure the same
/// height: that is the check that the skeleton's inertness costs no geometry. It stays the right
/// question after the chips became stand-ins, because the capsule the skeleton paints takes its
/// frame from a redacted + disabled Menu — this one, `.hidden()`.
///
/// `python3 scripts/render-ruler.py --pt-width 900 --scan-col 0.28,0.72` — the two probe runs must
/// share a top edge and a height.
///
/// 420, not the ~270 the three rows need on iOS: at the tvOS ramp's 64pt menus the same stack runs
/// past 260 and the probe row clips off the canvas, which is the row that carries the check.
#Preview("Header skeleton ↔ live", traits: .fixedLayout(width: 900, height: 420)) {
    VStack(spacing: 0) {
        LibraryHeaderControlsSkeleton()
        LibraryHeaderControls(
            sortField: .title,
            sortDirection: .ascending,
            selectedGenre: nil,
            availableGenres: ["Action", "Drama"],
            isLoadingGenres: false,
            onSelectField: { _ in },
            onSelectDirection: { _ in },
            onSelectGenre: { _ in }
        )
        HStack(alignment: .top, spacing: 0) {
            sortChipProbe(inert: false)
                .frame(maxWidth: .infinity)
            sortChipProbe(inert: true)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, Space.s30)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(.black)
    .preferredColorScheme(.dark)
    .tint(Color.label)
}

/// One probe chip — the shipping Sort menu on an opaque fill so its frame is measurable, optionally
/// wearing the skeleton's `.redacted` + `.disabled` pair.
@ViewBuilder
private func sortChipProbe(inert: Bool) -> some View {
    let chip = libraryHeaderMenu(
        title: "Sort",
        systemImage: "arrow.up.arrow.down",
        accessibilityLabel: "Sort"
    ) {
        Text("Sort")
    }
    .background(Color.fill)

    if inert {
        chip.redacted(reason: .placeholder).disabled(true)
    } else {
        chip
    }
}
#endif
