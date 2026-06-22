import SwiftUI

/// Trailing affordance on a settings pill.
enum SettingsRowAccessory {
    /// Navigation chevron (drill-in).
    case chevron
    /// Destructive trash glyph (remove).
    case trash
    case none
}

/// One settings/connect option, drawn as a STANDALONE PILL — a self-contained rounded row (title +
/// optional subtitle, optional trailing status/value/accessory) sitting on its own flat fill, spaced
/// from its neighbours by `SettingsGroup`. This is the tvOS Settings.app idiom: each option is its own
/// pill, NOT a row fused into a grouped-list container.
///
/// `systemImage` follows each platform's Settings convention: the leading glyph renders on iOS/iPadOS
/// (matching iOS Settings' icon column) but is suppressed on tvOS, whose Settings pills are pure
/// text + chevron with NO leading icon. On tvOS the pill brightens to the opaque-white focus platter
/// (content inverts to ink via the `colorScheme` flip) and lifts gently; no Liquid Glass. On iOS it's
/// just the flat rest pill (no focus state).
struct SettingsRowLabel: View {
    var systemImage: String? = nil
    /// A custom template asset for the leading glyph (e.g. the Jellyfin mark), used in place of an
    /// SF Symbol when set. Tinted like the symbol, so a monochrome template is expected.
    var image: String? = nil
    var title: String
    var subtitle: String? = nil
    var value: String? = nil
    var accessory: SettingsRowAccessory = .none
    var isDestructive: Bool = false

    var body: some View {
        HStack(spacing: Space.s14) {
            // iOS keeps the leading icon column (iOS Settings idiom); tvOS Settings pills are icon-less.
            #if !os(tvOS)
            if let image {
                Image(image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: SettingsListRow.symbolColumnWidth, height: 22)
                    .foregroundStyle(isDestructive ? Color.red : Color.secondaryLabel)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.rowBody)
                    .frame(width: SettingsListRow.symbolColumnWidth)
                    .foregroundStyle(isDestructive ? Color.red : Color.secondaryLabel)
            }
            #endif
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.rowBody)
                    .foregroundStyle(isDestructive ? Color.red : Color.label)
                if let subtitle {
                    Text(subtitle)
                        .font(.rowSubtitle)
                        .foregroundStyle(Color.secondaryLabel)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Space.s14)
            if let value {
                Text(value)
                    .font(.rowBody)
                    .foregroundStyle(Color.secondaryLabel)
                    .lineLimit(1)
            }
            accessoryView
        }
        .settingsPillLayout()
        // Read title + subtitle + status as ONE VoiceOver element rather than separate swipe stops
        // (Button-wrapped rows already combine, but static info rows would otherwise fragment).
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var accessoryView: some View {
        switch accessory {
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.rowSubtitle.weight(.semibold))
                .foregroundStyle(Color.tertiaryLabel)
        case .trash:
            Image(systemName: "trash")
                .font(.rowBody)
                .foregroundStyle(Color.red)
        case .none:
            EmptyView()
        }
    }
}

/// The standalone Settings pill chrome, exposed as reusable modifiers so `SettingsRowLabel` and the
/// tvOS credential rows (`CredentialRowList`) share ONE pill contract and can't drift apart.
extension View {
    /// The FULL pill: standard inset + min height + capsule hit-shape + the `settingsPill()` platter.
    /// Both the settings rows and the credential rows apply this, so their padding/height/shape stay
    /// identical from one source.
    func settingsPillLayout() -> some View {
        self
            .padding(.horizontal, Space.s26)
            .padding(.vertical, Space.s12)
            .frame(minHeight: SettingsListRow.pillMinHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.capsule)
            .settingsPill()
    }

    /// Just the platter (flat fill at rest, tvOS white focus platter on focus). `settingsPillLayout()`
    /// builds on this; use it directly only when the surrounding layout differs.
    func settingsPill() -> some View { modifier(SettingsPill()) }
}

/// Paints the pill: a flat rounded fill at rest, brightening to the opaque-white tvOS focus platter on
/// focus (content inverts to ink via the `colorScheme` flip) with a GENTLE lift — the real Settings.app
/// pill barely shadows, so the lift reads as a soft float, not a popped card. The pill is the row's OWN
/// shape — there's spacing around it, so the lift can't bleed into a neighbour. iOS gets only the flat
/// rest fill (no focus). Reuses the `TVFocusReader` focus-chrome contract.
private struct SettingsPill: ViewModifier {
    private let shape = Capsule(style: .continuous)

    func body(content: Content) -> some View {
        #if os(tvOS)
        TVFocusReader { focused in
            content
                .background(shape.fill(Color.fill).opacity(focused ? 0 : 1))
                .background(shape.fill(Color.white).opacity(focused ? 1 : 0))
                .environment(\.colorScheme, focused ? .light : .dark)
                .scaleEffect(focused ? 1.03 : 1)
                .shadow(color: .black.opacity(focused ? 0.22 : 0), radius: focused ? 11 : 0, y: focused ? 6 : 0)
                .animation(.tvFocusChrome, value: focused)
        }
        #else
        content.background(shape.fill(Color.fill))
        #endif
    }
}

/// Convenience wrapper around `SettingsRowLabel` for the two common cases: an action pill (a `Button`,
/// quiet style so only the pill's own focus chrome shows) or a static info pill (no button). For a
/// navigation pill, use `SettingsRowLabel` as a `NavigationLink`'s label + `.tvListRowButton()`.
struct SettingsListRow: View {
    /// Leading SF-Symbol column width.
    static let symbolColumnWidth: CGFloat = 38
    /// Pill height. On iOS the floor is the natural height of a TWO-line row (title + subtitle) at the
    /// default text size, so a single-line row clamps UP to match it and every pill reads as one height:
    /// standalone capsules can't lean on a shared list separator to hide height variance, so uneven pills
    /// read as misalignment. (It's a floor, not a fixed height — at large Dynamic Type a two-line row
    /// still grows past it, which is correct; uniformity is the default-size guarantee.) tvOS pills are
    /// all single-line (icon-less text), so they're uniform at the compact 58pt already.
    static var pillMinHeight: CGFloat {
        #if os(tvOS)
        58
        #else
        64
        #endif
    }

    var systemImage: String? = nil
    /// Custom template asset for the leading glyph (e.g. the Jellyfin mark), in place of an SF Symbol.
    var image: String? = nil
    var title: String
    var subtitle: String? = nil
    var value: String? = nil
    var accessory: SettingsRowAccessory = .none
    var role: ButtonRole? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        if let action {
            Button(role: role, action: action) { label }
                .tvListRowButton()
        } else {
            label
        }
    }

    private var label: some View {
        SettingsRowLabel(
            systemImage: systemImage,
            image: image,
            title: title,
            subtitle: subtitle,
            value: value,
            accessory: accessory,
            isDestructive: role == .destructive
        )
    }
}
