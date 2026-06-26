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
