#if !os(tvOS)
import SwiftUI
import ParallaxJellyfin
import ParallaxCore

/// The library's nav-bar sort+genre menu: the direction pair as a Photos-style tile row, the sort
/// fields, and Genre as a nested submenu. A plain SwiftUI `Menu` with a `Label` so the system can
/// lay it out like any toolbar item: on the iPhone Duo it joins the side toolbar with Back, and in
/// an overflow menu it shows its title. Mounting needs no view model (it renders from plain
/// values), which keeps the toolbar item from only appearing after the push animation settled.
struct LibrarySortMenuButton: View {
    let sortField: ItemSort.Field
    let sortDirection: ItemSort.Direction
    let selectedGenre: String?
    let availableGenres: [String]
    /// False until the grid's view model exists — the button is visible
    /// immediately but inert for that first beat.
    let isEnabled: Bool
    let onSelectField: (ItemSort.Field) -> Void
    let onSelectDirection: (ItemSort.Direction) -> Void
    let onSelectGenre: (String?) -> Void

    var body: some View {
        Menu {
            SortMenuSections(fields: ItemSort.Field.allCases, field: sortField,
                             fieldLabel: LibrarySortVocabulary.label(for:),
                             directionOptions: LibrarySortVocabulary.directionOptions(for: sortField),
                             direction: sortDirection,
                             onSelectField: onSelectField, onSelectDirection: onSelectDirection)
            if !availableGenres.isEmpty {
                Picker(selection: Binding(get: { selectedGenre }, set: onSelectGenre)) {
                    Text("All Genres").tag(String?.none)
                    ForEach(availableGenres, id: \.self) { Text($0).tag(Optional($0)) }
                } label: {
                    Label(selectedGenre ?? "Genre", systemImage: "theatermasks")
                }
                .pickerStyle(.menu)
            }
        } label: {
            // Resting: the bare funnel. A genre filter flips it to the filled-disc variant: the
            // stock active-filter signal, and the only in-palette state change a monochrome bar has.
            Label("Sort and Genre", systemImage: selectedGenre == nil
                  ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
        .disabled(!isEnabled)
        .accessibilityValue(selectedGenre ?? "")
    }
}

#if DEBUG
/// Bar-symmetry ruler for the library screen, in real pushed-state chrome: a
/// system BACK button leading, the sort menu trailing, red rules at
/// the grid's content margin on BOTH edges, and a poster stand-in flush to
/// each rule. What it proves (run `scripts/render-ruler.py --pt-width 398
/// --scan-row auto --scan-from 0` after rendering DARK): both platters park at
/// the system 16pt, mirror-symmetric, each flush with its tile edge. The open
/// menu itself only exists at runtime.
#Preview("Library bar alignment", traits: .fixedLayout(width: 393, height: 740)) {
    NavigationStack(path: .constant(NavigationPath(["grid"]))) {
        Color.background
            .navigationDestination(for: String.self) { _ in
                ScrollView {
                    HStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.blue.opacity(0.5))
                            .frame(width: 110, height: 160)
                        Spacer()
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.blue.opacity(0.5))
                            .frame(width: 110, height: 160)
                    }
                }
                .contentMargins(.horizontal, AppLayout.contentHMargin(idiom: .compact), for: .scrollContent)
                .previewRuler(
                    leading: AppLayout.contentHMargin(idiom: .compact),
                    trailing: AppLayout.contentHMargin(idiom: .compact)
                )
                .navigationTitle("Movies")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        LibrarySortMenuButton(
                            sortField: .releaseDate,
                            sortDirection: .descending,
                            selectedGenre: nil,
                            availableGenres: ["Action", "Drama"],
                            isEnabled: true,
                            onSelectField: { _ in },
                            onSelectDirection: { _ in },
                            onSelectGenre: { _ in }
                        )
                    }
                }
            }
    }
}
#endif
#endif
