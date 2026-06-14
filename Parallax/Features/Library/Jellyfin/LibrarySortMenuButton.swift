#if !os(tvOS)
import SwiftUI
import UIKit
import ParallaxJellyfin
import ParallaxCore

/// The library's nav-bar sort button, bridged to UIKit for ONE reason: the
/// Photos-style direction row — two tiles with the icon ABOVE its title and a
/// selected pill — is `UIMenu.preferredElementSize = .medium`, an API SwiftUI
/// doesn't expose. SwiftUI's `.palette` picker renders the same row as bare
/// icon circles under a stray "Order" header (shipped, looked broken).
///
/// The menu is rebuilt from the latest state on every SwiftUI update; UIKit
/// snapshots children at presentation and every row tap dismisses, so the
/// rebuild always lands before the next open. Mounting the button needs no
/// view model (it renders from plain values), which also fixes the toolbar
/// item only appearing after the push animation settled.
struct LibrarySortMenuButton: UIViewRepresentable {
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

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        // Monochrome chrome rule: never the inherited accent. (tintColor = nil
        // here resolves to the SAME label color anyway — RootView pins
        // `.tint(Color.label)` — so a tint flip can't signal anything.)
        button.tintColor = .label
        button.accessibilityLabel = "Sort and genre"
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        // Resting: the bare funnel, no enclosing circle — the glass toolbar
        // platter already provides the shape. A genre filter flips it to the
        // filled-disc variant: the stock active-filter signal, and the only
        // in-palette state change a monochrome bar has (a tint swap is
        // invisible when everything is already label-colored).
        // Body + large scale matches the symbol metrics SwiftUI gives its own
        // toolbar items (UIButton's bare default renders a beat smaller than
        // the neighbouring bar glyphs).
        let config = UIImage.SymbolConfiguration(textStyle: .body, scale: .large)
        let glyph = selectedGenre != nil
            ? "line.3.horizontal.decrease.circle.fill"
            : "line.3.horizontal.decrease"
        button.setImage(UIImage(systemName: glyph, withConfiguration: config), for: .normal)
        button.menu = menu()
        button.isEnabled = isEnabled
        button.accessibilityValue = selectedGenre ?? ""
    }

    /// Report the glyph's intrinsic size: without this the representable takes
    /// the whole proposed toolbar slot and the glass platter stretches into a
    /// bar-wide pill instead of the standard item circle.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        uiView.intrinsicContentSize
    }

    private func menu() -> UIMenu {
        // Direction tiles — icon over title, selected pill: the `.medium`
        // element size this whole bridge exists for.
        let directionRow = UIMenu(
            options: .displayInline,
            children: LibrarySortVocabulary.directionOptions(for: sortField).map { option in
                UIAction(
                    title: option.title,
                    image: UIImage(systemName: option.icon),
                    state: sortDirection == option.direction ? .on : .off
                ) { _ in onSelectDirection(option.direction) }
            }
        )
        directionRow.preferredElementSize = .medium

        let fields = UIMenu(
            options: .displayInline,
            children: ItemSort.Field.allCases.map { field in
                UIAction(
                    title: LibrarySortVocabulary.label(for: field),
                    state: sortField == field ? .on : .off
                ) { _ in onSelectField(field) }
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
