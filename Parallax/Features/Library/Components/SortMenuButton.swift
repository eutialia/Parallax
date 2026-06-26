#if !os(tvOS)
import SwiftUI
import UIKit

/// Reusable nav-bar sort button bridged to UIKit for ONE reason: the Photos-style direction row —
/// two tiles with the icon ABOVE its title and a selected pill — is `UIMenu.preferredElementSize =
/// .medium`, an API SwiftUI doesn't expose (its `.palette` picker renders bare icon circles under a
/// stray header). The OWNER builds the `menu` (direction tiles via `directionRow`, fields via
/// `fieldRows`, plus any extra sections) so neither the Jellyfin field set + genre submenu nor the
/// SMB field set leaks into this chrome — the bridge stays the single place the `.medium` row, the
/// monochrome tint, and the symbol metrics live.
///
/// The menu is rebuilt from the latest state on every SwiftUI update; UIKit snapshots children at
/// presentation and every row tap dismisses, so the rebuild always lands before the next open.
struct SortMenuButton: UIViewRepresentable {
    /// Resting bar glyph (e.g. `arrow.up.arrow.down`).
    let glyph: String
    /// Swapped in when `isActive` — the genre-filter "filled funnel". nil keeps `glyph` constant
    /// (SMB browse is sort-only and has no active state).
    let activeGlyph: String?
    let isActive: Bool
    /// The fully-built menu. Pass a freshly-built value each update so it snapshots current state.
    let menu: UIMenu
    /// False until the owner's view model exists — the button is visible immediately but inert for
    /// that first beat (a toolbar item inserted mid-push doesn't render until the transition settles,
    /// so it must mount unconditionally, then enable).
    let isEnabled: Bool
    let accessibilityLabel: String
    let accessibilityValue: String

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        // Monochrome chrome rule: never the inherited accent (RootView pins `.tint(Color.label)`, so
        // `.label` here resolves to the same color — a tint flip can't signal anything anyway).
        button.tintColor = .label
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        // Body + large scale matches the symbol metrics SwiftUI gives its own toolbar items
        // (UIButton's bare default renders a beat smaller than the neighbouring bar glyphs).
        let config = UIImage.SymbolConfiguration(textStyle: .body, scale: .large)
        let name = (isActive ? activeGlyph : nil) ?? glyph
        button.setImage(UIImage(systemName: name, withConfiguration: config), for: .normal)
        button.menu = menu
        button.isEnabled = isEnabled
        button.accessibilityLabel = accessibilityLabel
        button.accessibilityValue = accessibilityValue
    }

    /// Report the glyph's intrinsic size: without this the representable takes the whole proposed
    /// toolbar slot and the glass platter stretches into a bar-wide pill instead of the item circle.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        uiView.intrinsicContentSize
    }
}

extension SortMenuButton {
    /// One choice in a sort menu: a title, an optional SF Symbol, whether it's the current selection,
    /// and the tap action.
    struct Option {
        let title: String
        let icon: String?
        let isOn: Bool
        let action: () -> Void

        init(title: String, icon: String? = nil, isOn: Bool, action: @escaping () -> Void) {
            self.title = title
            self.icon = icon
            self.isOn = isOn
            self.action = action
        }
    }

    /// The Photos-style `.medium` direction tile row (icon over title, selected pill).
    static func directionRow(_ options: [Option]) -> UIMenu {
        let row = UIMenu(options: .displayInline, children: options.map(action))
        row.preferredElementSize = .medium
        return row
    }

    /// The inline sort-field list (system leading checkmark on the selected one).
    static func fieldRows(_ options: [Option]) -> UIMenu {
        UIMenu(options: .displayInline, children: options.map(action))
    }

    private static func action(_ option: Option) -> UIAction {
        UIAction(
            title: option.title,
            image: option.icon.flatMap { UIImage(systemName: $0) },
            state: option.isOn ? .on : .off
        ) { _ in option.action() }
    }
}
#endif
