import SwiftUI

/// One row in a settings list-card: an icon tile, a title, an optional trailing value,
/// and an optional chevron — the design handoff's `SetRow`. Given an `action` it renders
/// as a Button; otherwise it's a static read-only info row. `role: .destructive` tints
/// the icon tile and title red (the global `.tint` is monochrome, so the destructive
/// colour is applied explicitly rather than relying on the system button role).
struct SettingsRow: View {
    /// Fixed icon-tile width. Exposed so a settings screen's row separators can inset
    /// past the tile from a single source of truth (see `separatorLeadingInset`).
    static let iconTileSize: CGFloat = 30
    /// Leading inset for a row hairline that should start past the icon tile + its gutter.
    static let separatorLeadingInset: CGFloat = Space.s14 + iconTileSize + Space.s12

    let systemImage: String
    let title: String
    var value: String? = nil
    var showsChevron: Bool = true
    var role: ButtonRole? = nil
    var action: (() -> Void)? = nil

    private var isDestructive: Bool { role == .destructive }

    var body: some View {
        if let action {
            // tvOS: a quiet style (no system focus platter) + the row's own contained platter via
            // `tvFocusListRow()` — `.plain` here painted an overflowing white box bleeding over the
            // neighbouring rows. `.plain` on iOS (unchanged there).
            Button(role: role, action: action) { rowLabel.tvFocusListRow() }
                .tvListRowButton()
        } else {
            rowLabel
        }
    }

    private var rowLabel: some View {
        HStack(spacing: Space.s12) {
            IconTile(
                systemImage: systemImage,
                size: Self.iconTileSize,
                cornerRadius: 8,
                glyphSize: 15,
                fill: isDestructive ? Color.red.opacity(0.16) : Color.fill,
                foreground: isDestructive ? Color.red : Color.label
            )
            Text(title)
                .font(.rowBody)
                .foregroundStyle(isDestructive ? Color.red : Color.label)
            Spacer(minLength: Space.s8)
            if let value {
                Text(value)
                    .font(.rowBody)
                    .foregroundStyle(Color.secondaryLabel)
                    .lineLimit(1)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .scaledFont(13, relativeTo: .footnote, weight: .semibold)
                    .foregroundStyle(Color.tertiaryLabel)
            }
        }
        .padding(.horizontal, Space.s14)
        .frame(minHeight: 52)
        .contentShape(.rect)
    }
}
