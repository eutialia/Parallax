import SwiftUI
import ParallaxFileBrowse

/// One share row in an SMB picker list: a leading `SelectionCircle` + drive glyph + name + optional
/// comment. Shared by the connect-flow share selector (`SMBShareSelectionView`) and the per-server
/// settings toggle list (`SMBServerSettingsView`) — both are share-name pickers with an identical
/// visual + interaction contract, so they render through ONE component instead of drifting copies
/// (they previously diverged on hit-shape, focus treatment, and accessibility).
///
/// Follows the canonical grouped-settings-row focus recipe: `tvFocusListRow()` on the label (the
/// contained white focus platter, content inverts to ink) paired with `tvListRowButton()` on the
/// button — the SAME pairing `SettingsListRow`/`SettingsRowLabel` use. A separate `.buttonStyle(.plain)`
/// is deliberately omitted: an inner `.plain` defeats `tvListRowButton()`'s tvOS style, so on Apple TV
/// the row would focus with the bare system box instead of the platter.
struct ShareSelectionRow: View {
    let share: SMBShare
    /// Whether the share is currently enabled/selected — drives the leading `SelectionCircle`.
    let isSelected: Bool
    /// The share is enabled but no longer exists on the server (removed or renamed server-side). It
    /// stays persisted (so the circle still reads `.on`), but the glyph + subtitle mark it unavailable
    /// and toggling it OFF is the only way to drop the now-dead library. The connect flow never sets
    /// this — every offered share is live.
    var isUnavailable: Bool = false
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: Space.s12) {
                SelectionCircle(state: isSelected ? .on : .off)

                HStack(spacing: Space.s12) {
                    Image(systemName: isUnavailable ? "externaldrive.badge.xmark" : "externaldrive")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.secondaryLabel)
                        .frame(width: SettingsListRow.glyphColumnWidth, alignment: .center)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(share.name)
                            .font(.rowBody)
                            .foregroundStyle(isUnavailable ? Color.secondaryLabel : Color.label)
                            .lineLimit(1)
                        if let subtitle {
                            Text(subtitle)
                                .font(.rowSubtitle)
                                .foregroundStyle(Color.secondaryLabel)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: Space.s12)
                }
            }
            .padding(.horizontal, SettingsMetrics.rowHInset)
            .padding(.vertical, Space.s12)
            .frame(minHeight: SettingsListRow.rowMinHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .tvFocusListRow()
        }
        .tvListRowButton()
        .accessibilityValue(accessibilityValue)
    }

    /// Unavailable rows explain themselves; otherwise show the server's share comment when present.
    private var subtitle: String? {
        if isUnavailable { return "Unavailable on server" }
        return share.comment.isEmpty ? nil : share.comment
    }

    private var accessibilityValue: String {
        if isUnavailable { return "Unavailable" }
        return isSelected ? "Enabled" : "Disabled"
    }
}

#if DEBUG
#Preview("Share selection rows · states", traits: .fixedLayout(width: 540, height: 620)) {
    let shares = [
        SMBShare(name: "Media", comment: "Movies & TV"),
        SMBShare(name: "Backups", comment: ""),
        SMBShare(name: "Photos", comment: "Family photos"),
    ]
    ScrollView {
        VStack(spacing: Space.s18) {
            // Footer mirrors SMBServerSettingsView.sharesFooter's unavailable-present variant, so the
            // render shows the full combined state: live rows + an unavailable row + the recovery hint.
            SettingsGroup(
                title: "Shares",
                footer: "Choose which shares on this server appear as libraries in Parallax. Turn off an unavailable share to remove its library."
            ) {
                ShareSelectionRow(share: shares[0], isSelected: true) {}
                ShareSelectionRow(share: shares[1], isSelected: false) {}
                ShareSelectionRow(share: shares[2], isSelected: true) {}
                // Enabled but gone server-side: the un-removable-tab recovery row.
                ShareSelectionRow(
                    share: SMBShare(name: "OldArchive", comment: ""),
                    isSelected: true,
                    isUnavailable: true
                ) {}
            }
        }
        .padding(Space.s18)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color.background)
}
#endif
