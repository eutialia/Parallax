import SwiftUI
import ParallaxCore

/// Skeleton capsule metrics for the tvOS in-content header's loading state — shared by the live
/// `LibraryHeaderControls` and the grids' first-load placeholders so the skeleton→real-controls
/// swap is shift-free. The real Genre/Sort chips are native `.glass` Menus that size themselves
/// from their labels, so these approximate that footprint; the height reuses the app-wide control
/// height.
enum LibraryHeaderChip {
    static let height: CGFloat = AppLayout.tvControlHeight
    static let genreWidth: CGFloat = 140
    static let sortWidth: CGFloat = 110
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
            sortMenu
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
            genreMenu
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

/// The tvOS header's loading skeleton — two centered capsules matching `LibraryHeaderControls`'
/// geometry (both slots present) so the skeleton→real-controls swap stays symmetric and
/// shift-free, including its padding.
struct LibraryHeaderControlsSkeleton: View {
    var body: some View {
        HStack(spacing: Space.s12) {
            Capsule().fill(Color.fill).frame(width: LibraryHeaderChip.genreWidth, height: LibraryHeaderChip.height)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Capsule().fill(Color.fill).frame(width: LibraryHeaderChip.sortWidth, height: LibraryHeaderChip.height)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, AppLayout.chipRowTopPadding)
        .padding(.bottom, AppLayout.chipRowBottomClearance)
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
#endif
