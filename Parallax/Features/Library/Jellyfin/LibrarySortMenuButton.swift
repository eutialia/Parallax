#if !os(tvOS)
import SwiftUI
import UIKit
import ParallaxJellyfin
import ParallaxCore

/// The library's nav-bar sort+genre button. The Photos-style `.medium` direction tiles + the
/// monochrome bridge live in the shared `SortMenuButton`; this just builds the Jellyfin field set
/// and the genre submenu (the one piece SMB browse doesn't share) and hands over a `UIMenu`.
/// Mounting needs no view model (it renders from plain values), which keeps the toolbar item from
/// only appearing after the push animation settled.
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
        // Resting: the bare funnel — the glass toolbar platter already provides the shape. A genre
        // filter flips it to the filled-disc variant: the stock active-filter signal, and the only
        // in-palette state change a monochrome bar has (a tint swap is invisible when everything is
        // already label-colored).
        SortMenuButton(
            glyph: "line.3.horizontal.decrease",
            activeGlyph: "line.3.horizontal.decrease.circle.fill",
            isActive: selectedGenre != nil,
            menu: menu(),
            isEnabled: isEnabled,
            accessibilityLabel: "Sort and genre",
            accessibilityValue: selectedGenre ?? ""
        )
    }

    private func menu() -> UIMenu {
        let directionRow = SortMenuButton.directionRow(
            LibrarySortVocabulary.directionOptions(for: sortField).map { option in
                .init(title: option.title, icon: option.icon, isOn: sortDirection == option.direction) {
                    onSelectDirection(option.direction)
                }
            }
        )
        let fields = SortMenuButton.fieldRows(
            ItemSort.Field.allCases.map { field in
                .init(title: LibrarySortVocabulary.label(for: field), isOn: sortField == field) {
                    onSelectField(field)
                }
            }
        )

        var sections: [UIMenuElement] = [directionRow, fields]
        if !availableGenres.isEmpty {
            let allGenres = UIAction(
                title: "All Genres",
                state: selectedGenre == nil ? .on : .off
            ) { _ in onSelectGenre(nil) }
            let genreActions = availableGenres.map { genre in
                UIAction(title: genre, state: selectedGenre == genre ? .on : .off) { _ in
                    onSelectGenre(genre)
                }
            }
            let genreSubmenu = UIMenu(
                title: selectedGenre ?? "Genre",
                image: UIImage(systemName: "theatermasks"),
                children: [allGenres] + genreActions
            )
            // Own inline wrapper so the submenu gets a section separator above,
            // like the SwiftUI `Section` it replaces.
            sections.append(UIMenu(options: .displayInline, children: [genreSubmenu]))
        }
        return UIMenu(children: sections)
    }
}

#if DEBUG
/// Bar-symmetry ruler for the library screen, in real pushed-state chrome: a
/// system BACK button leading, the bridged sort button trailing, red rules at
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
