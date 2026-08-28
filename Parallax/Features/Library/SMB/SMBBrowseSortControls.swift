import SwiftUI
import ParallaxFileBrowse
#if !os(tvOS)
import UIKit
#endif

/// One vocabulary for the SMB browse sort UI on every platform — the iOS nav-bar button and the
/// tvOS in-content chip read the same field names and the same human direction pairs, so "Newest"
/// means the same thing everywhere or nowhere. The SMB sibling of `LibrarySortVocabulary`; the two
/// stay separate because their fields are different domains (SMB has only what the filesystem
/// records: a name and two timestamps).
enum SMBBrowseSortVocabulary {
    /// Human-language direction pair for a field — what ascending/descending MEAN for it, natural
    /// order first. Shares the generic `SortDirectionOption` shape with `LibrarySortVocabulary`.
    typealias DirectionOption = SortDirectionOption<SMBBrowseSort.Direction>

    static func label(for field: SMBBrowseSort.Field) -> String {
        switch field {
        case .name: "Name"
        case .dateModified: "Date Modified"
        case .dateCreated: "Date Created"
        }
    }

    static func directionOptions(for field: SMBBrowseSort.Field) -> [DirectionOption] {
        switch field {
        case .name:
            [
                DirectionOption(title: "A to Z", icon: "a.square", direction: .ascending),
                DirectionOption(title: "Z to A", icon: "z.square", direction: .descending),
            ]
        case .dateModified, .dateCreated:
            [
                DirectionOption(title: "Newest", icon: "clock", direction: .descending),
                DirectionOption(title: "Oldest", icon: "clock.arrow.circlepath", direction: .ascending),
            ]
        }
    }
}

#if !os(tvOS)
/// iPhone/iPad nav-bar SMB sort button: the shared `SortMenuButton` bridge driven by the SMB
/// vocabulary (sort-only — no genre submenu, unlike the Jellyfin `LibrarySortMenuButton`).
struct SMBBrowseSortButton: View {
    let field: SMBBrowseSort.Field
    let direction: SMBBrowseSort.Direction
    let isEnabled: Bool
    let onSelectField: (SMBBrowseSort.Field) -> Void
    let onSelectDirection: (SMBBrowseSort.Direction) -> Void

    var body: some View {
        SortMenuButton(
            glyph: "arrow.up.arrow.down",
            activeGlyph: nil,
            isActive: false,
            menu: menu(),
            isEnabled: isEnabled,
            accessibilityLabel: "Sort",
            accessibilityValue: SMBBrowseSortVocabulary.label(for: field)
        )
    }

    private func menu() -> UIMenu {
        let directionRow = SortMenuButton.directionRow(
            SMBBrowseSortVocabulary.directionOptions(for: field).map { option in
                .init(title: option.title, icon: option.icon, isOn: direction == option.direction) {
                    onSelectDirection(option.direction)
                }
            }
        )
        let fields = SortMenuButton.fieldRows(
            SMBBrowseSort.Field.allCases.map { f in
                .init(title: SMBBrowseSortVocabulary.label(for: f), isOn: field == f) {
                    onSelectField(f)
                }
            }
        )
        return UIMenu(children: [directionRow, fields])
    }
}
#endif

/// The tvOS in-content sort row: the chip centered above the wall, carrying the shared chip-row
/// padding pair and the focus section that lets Up from any poster column divert to it. Toolbar
/// items can't join the tvOS focus engine, so Sort rides inside the focusable scroll (iPhone/iPad
/// keep it in the nav bar, so this is empty there — the type exists on both platforms so callers
/// need no `#if` of their own).
///
/// It's a view rather than a method on `SMBBrowseView` so the skeleton↔wall parity preview renders
/// the SHIPPING row in its loaded half instead of omitting it: without it the preview's loaded
/// tiles started ~104pt above the skeleton's and the render certified a screen the app never draws.
/// `SMBBrowseSortChipSkeleton` stands in for exactly this row.
struct SMBBrowseSortHeader: View {
    @Binding var field: SMBBrowseSort.Field
    @Binding var direction: SMBBrowseSort.Direction

    var body: some View {
        #if os(tvOS)
        SMBBrowseSortChip(field: $field, direction: $direction)
            .frame(maxWidth: .infinity, alignment: .center)
            // The shared chip-row tokens (not raw Space values): `SMBBrowseSortChipSkeleton` reads
            // the same pair, so the skeleton→chip swap stays coupled by compiler.
            .padding(.top, AppLayout.chipRowTopPadding)
            .padding(.bottom, AppLayout.chipRowBottomClearance)
            .tvFocusSection()
        #else
        EmptyView()
        #endif
    }
}

/// The sort chip's first-load stand-in — the REAL `SMBBrowseSortChip`, `.hidden()` under a flat
/// capsule (`skeletonStandIn`), so the row `SMBBrowseLoadingSkeleton` reserves is the shipping
/// control's footprint (a native `.glass` Menu sized by its own label and type ramp) instead of a
/// hand-guessed capsule. It carries the chip row's padding pair too, exactly as
/// `SMBBrowseView.sortHeader` does. The same pattern the library header uses — there via
/// `\.redactionReasons`, because there the skeleton renders the whole live header and only the chips
/// swap; here the wrapper IS the placeholder, so it applies the stand-in directly.
///
/// Redaction is deliberately NOT used: it masks the label's glyphs but leaves the `.glass` capsule
/// on, and `skeletonShimmer()` masks with a second copy of its content — the material composited
/// twice and the row read as a dimmed live chip, not a flat bar.
///
/// `.disabled(true)` is load-bearing: a placeholder that takes tvOS focus is a bug, and disabled
/// controls are skipped by the focus engine. (The hidden chip couldn't take focus anyway — hidden
/// views "can't receive or respond to interactions" — but the guard is cheap and states the intent.)
/// No `.allowsHitTesting(false)`: it's unreliable on tvOS and `.disabled` already blocks activation.
///
/// Empty on iPhone/iPad — sort lives in the nav bar there, so the content has no chip row to
/// reserve. The type exists on both platforms so the skeleton needs no `#if` of its own.
struct SMBBrowseSortChipSkeleton: View {
    var body: some View {
        #if os(tvOS)
        // Constant bindings, not `@State`: nothing can move them — the chip is hidden and disabled.
        SMBBrowseSortChip(
            field: .constant(SMBBrowseSort.default.field),
            direction: .constant(SMBBrowseSort.default.direction)
        )
        .skeletonStandIn(in: Capsule())
        .disabled(true)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, AppLayout.chipRowTopPadding)
        .padding(.bottom, AppLayout.chipRowBottomClearance)
        #else
        EmptyView()
        #endif
    }
}

#if os(tvOS)
/// tvOS in-content SMB sort chip — toolbar items can't join the focus engine on tvOS, so the
/// control rides inside the scrollable content (`SMBBrowseView.sortHeader`, centered above the
/// grid). Mirrors the `LibraryGridView` header chip: a native `.glass` Menu with inline pickers,
/// `Color.label` tint.
struct SMBBrowseSortChip: View {
    @Binding var field: SMBBrowseSort.Field
    @Binding var direction: SMBBrowseSort.Direction

    var body: some View {
        Menu {
            Picker("Order", selection: $direction) {
                ForEach(SMBBrowseSortVocabulary.directionOptions(for: field), id: \.direction) { option in
                    Label(option.title, systemImage: option.icon).tag(option.direction)
                }
            }
            .pickerStyle(.inline)
            Picker("Sort By", selection: $field) {
                ForEach(SMBBrowseSort.Field.allCases, id: \.self) { f in
                    Text(SMBBrowseSortVocabulary.label(for: f)).tag(f)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.medium))
        }
        .buttonStyle(.glass)
        .tint(Color.label)
        .accessibilityLabel("Sort")
    }
}
#endif
