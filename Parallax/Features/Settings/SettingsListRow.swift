import SwiftUI

/// Trailing affordance on a grouped settings row.
enum SettingsRowAccessory: Equatable {
    /// Navigation chevron (drill-in).
    case chevron
    /// "Soon" placeholder badge — a non-interactive, dimmed row.
    case soon
    /// A trailing checkmark — a selected/included row (the Visible Libraries toggles).
    case checkmark
    case none
}

/// One row of the inset-grouped settings/connect surface, drawn FLAT — the rounded card and the
/// inter-row hairlines come from the enclosing `SettingsGroup`, so a row paints no background of its
/// own (the previous standalone-pill idiom is gone). Leading glyph column + title (optional 2-line
/// subtitle) + optional trailing value + accessory. On tvOS the row lifts into the white focus platter
/// via `tvFocusListRow()` (content inverts to ink); iOS is the flat rest row.
struct SettingsRowLabel: View {
    var systemImage: String? = nil
    /// A custom template asset for the leading glyph (e.g. the Jellyfin mark), used in place of an
    /// SF Symbol when set. Tinted like the symbol, so a monochrome template is expected.
    var image: String? = nil
    /// Leading glyph point size. Plain rows ~18; the 2-line server row passes a larger value.
    var iconSize: CGFloat = 18
    var title: String
    var subtitle: String? = nil
    var value: String? = nil
    var accessory: SettingsRowAccessory = .none
    var isDestructive: Bool = false
    /// Accent label (the "Add Server" row): the primary ink, emphasised — not a separate hue (the app's
    /// no-accent rule), just heavier weight in `Color.label`.
    var isAccent: Bool = false

    private var isDisabled: Bool { accessory == .soon }

    private var titleColor: Color {
        if isDestructive { return Color.destructive }
        return Color.label
    }

    var body: some View {
        HStack(spacing: Space.s12) {
            leadingGlyph
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(subtitle == nil ? .rowBody : .rowTitle)
                    .fontWeight(isAccent ? .semibold : nil)
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.rowSubtitle)
                        .foregroundStyle(Color.secondaryLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: Space.s12)
            if let value {
                Text(value)
                    .font(.rowValue)
                    .foregroundStyle(Color.secondaryLabel)
                    .lineLimit(1)
            }
            accessoryView
        }
        .opacity(isDisabled ? 0.5 : 1)
        .padding(.horizontal, SettingsMetrics.rowHInset)
        .padding(.vertical, Space.s12)
        .frame(minHeight: SettingsListRow.rowMinHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .tvFocusListRow()
        // Read title + subtitle + value + accessory as ONE VoiceOver element rather than separate stops.
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        Group {
            if let image {
                Image(image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: iconSize, weight: .medium))
            }
        }
        .foregroundStyle(isDestructive ? Color.destructive : Color.secondaryLabel)
        .frame(width: SettingsListRow.glyphColumnWidth, alignment: .center)
    }

    @ViewBuilder
    private var accessoryView: some View {
        switch accessory {
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.rowSubtitle.weight(.semibold))
                .foregroundStyle(Color.tertiaryLabel)
        case .soon:
            SoonBadge()
        case .checkmark:
            Image(systemName: "checkmark")
                .font(.rowBody.weight(.semibold))
                .foregroundStyle(Color.label)
        case .none:
            EmptyView()
        }
    }
}

/// A grouped settings row: an action row (a `Button`, quiet so only the row's own focus platter shows)
/// or a static info row (no button). For a navigation row, use `SettingsRowLabel` as a `NavigationLink`
/// label + `.tvListRowButton()`.
struct SettingsListRow: View {
    /// Leading glyph column width — the title's left edge sits one of these past the row inset, on every
    /// row, so titles align down a card regardless of glyph.
    static let glyphColumnWidth: CGFloat = 26
    /// Row floor. iOS clamps a single-line row UP to the natural height of a two-line (title+subtitle)
    /// row so every row in a card reads one height; tvOS is taller for the 10-foot type.
    static var rowMinHeight: CGFloat {
        #if os(tvOS)
        64
        #else
        48
        #endif
    }

    var systemImage: String? = nil
    var image: String? = nil
    var iconSize: CGFloat = 18
    var title: String
    var subtitle: String? = nil
    var value: String? = nil
    var accessory: SettingsRowAccessory = .none
    var isAccent: Bool = false
    var role: ButtonRole? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        if let action {
            Button(role: role, action: action) { label }
                .tvListRowButton()
                .disabled(accessory == .soon)
        } else {
            label
        }
    }

    private var label: some View {
        SettingsRowLabel(
            systemImage: systemImage,
            image: image,
            iconSize: iconSize,
            title: title,
            subtitle: subtitle,
            value: value,
            accessory: accessory,
            isDestructive: role == .destructive,
            isAccent: isAccent
        )
    }
}

extension Font {
    /// A settings row's trailing value (`jellyfin.example.lan`, `4 of 6`, `7.7 MB`). iOS keeps the
    /// handoff's ~15pt; tvOS floors at the readable 10-foot scale.
    static var rowValue: Font {
        #if os(tvOS)
        .system(size: 25, weight: .regular)
        #else
        .subheadline
        #endif
    }
}

// MARK: - tvOS credential-row pill (legacy contract)
//
// The tvOS `CredentialRowList` still draws each field as a standalone capsule pill via these modifiers.
// Kept verbatim while the Add-Server forms are restyled (P2); the grouped-card rows above no longer use
// them. Once the credential rows move onto the grouped-card idiom these can be deleted.

extension View {
    /// The FULL credential pill: inset + min height + capsule hit-shape + the `settingsPill()` platter.
    func settingsPillLayout() -> some View {
        self
            .padding(.horizontal, Space.s26)
            .padding(.vertical, Space.s8)
            .frame(minHeight: 58)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.capsule)
            .settingsPill()
    }

    /// Just the platter (flat fill at rest, tvOS white focus platter on focus).
    func settingsPill() -> some View { modifier(SettingsPill()) }
}

/// Paints the credential pill: a flat rounded fill at rest, brightening to the opaque-white tvOS focus
/// platter on focus (content inverts to ink via the `colorScheme` flip) with a gentle lift. iOS gets
/// only the flat rest fill.
private struct SettingsPill: ViewModifier {
    private let shape = Capsule(style: .continuous)
    #if os(tvOS)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// See `TVFocusListRowModifier`: focused forces `.light` (ink on the white platter); at rest keep
    /// the ambient appearance so the credential pill's label doesn't wash out on the Paper face.
    @Environment(\.colorScheme) private var ambient
    #endif

    func body(content: Content) -> some View {
        #if os(tvOS)
        TVFocusReader { focused in
            content
                .background(shape.fill(Color.fill).opacity(focused ? 0 : 1))
                .background(shape.fill(Color.white).opacity(focused ? 1 : 0))
                .environment(\.colorScheme, focused ? .light : ambient)
                .scaleEffect(focused && !reduceMotion ? 1.03 : 1)
                .shadow(color: .black.opacity(focused ? 0.22 : 0), radius: focused ? 11 : 0, y: focused ? 6 : 0)
                .animation(.tvFocusChrome, value: focused)
        }
        #else
        content.background(shape.fill(Color.fill))
        #endif
    }
}
