#if !os(tvOS)
import SwiftUI

/// One iOS credential field inside an inset-grouped form section — a leading glyph + the editor, drawn
/// FLAT so the rounded `Color.surface` card and the inter-field hairlines come from the enclosing
/// `SettingsGroup` (the same grouped-card idiom as the settings rows, replacing the old standalone
/// capsule pill). Shared by `LoginView` and `SMBLoginView` so the two sign-in forms can't drift apart.
/// tvOS uses `CredentialRowList` instead — single-field editor screens, not inline fields.
struct CredentialFieldRow<Content: View>: View {
    let icon: String
    @ViewBuilder var content: Content

    /// Scales with Dynamic Type so the editor never clips; the handoff field row is ~50pt tall.
    @ScaledMetric(relativeTo: .body) private var minHeight: CGFloat = 50

    var body: some View {
        HStack(spacing: Space.s12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.tertiaryLabel)
                .frame(width: SettingsListRow.glyphColumnWidth, alignment: .center)
            content
                .font(.rowBody)
                .tint(Color.label)
        }
        .padding(.horizontal, SettingsMetrics.rowHInset)
        .frame(minHeight: minHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A trailing "Show"/"Hide" reveal toggle for a password field, styled like the handoff's `.trail`.
struct PasswordRevealToggle: View {
    @Binding var isRevealed: Bool

    var body: some View {
        Button(isRevealed ? "Hide" : "Show") { isRevealed.toggle() }
            .font(.rowValue.weight(.semibold))
            .foregroundStyle(Color.secondaryLabel)
            .buttonStyle(.borderless)
    }
}

#if DEBUG
#Preview("Credential fields · grouped", traits: .fixedLayout(width: 540, height: 420)) {
    @Previewable @State var server = "http://jellyfin.example.lan"
    @Previewable @State var user = ""
    @Previewable @State var pass = "hunter2"
    @Previewable @State var reveal = false
    return VStack(spacing: Space.s18) {
        SettingsGroup(title: "Server") {
            CredentialFieldRow(icon: "globe") { TextField("Server", text: $server) }
        }
        SettingsGroup(title: "Account") {
            CredentialFieldRow(icon: "person") { TextField("Username", text: $user) }
            CredentialFieldRow(icon: "lock") {
                HStack {
                    Group { if reveal { TextField("Password", text: $pass) } else { SecureField("Password", text: $pass) } }
                    PasswordRevealToggle(isRevealed: $reveal)
                }
            }
        }
    }
    .padding(Space.s18)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .screenFloor()
}

#Preview("SMB form · fields", traits: .fixedLayout(width: 540, height: 460)) {
    @Previewable @State var host = "mynas.local"
    @Previewable @State var share = "Media"
    @Previewable @State var user = ""
    @Previewable @State var pass = ""
    @Previewable @State var reveal = false
    return VStack(spacing: Space.s18) {
        SettingsGroup(title: "Server", footer: "Your server’s address, then the name of the shared folder to open.") {
            CredentialFieldRow(icon: "externaldrive.badge.wifi") {
                HStack(spacing: 0) {
                    Text("smb://").foregroundStyle(Color.tertiaryLabel)
                    TextField("mynas.local", text: $host)
                }
            }
            CredentialFieldRow(icon: "folder") { TextField("Share name", text: $share) }
        }
        SettingsGroup(title: "Sign In", footer: "Leave blank to connect as a guest.") {
            CredentialFieldRow(icon: "person") { TextField("Username", text: $user) }
            CredentialFieldRow(icon: "lock") {
                HStack {
                    Group { if reveal { TextField("Password", text: $pass) } else { SecureField("Password", text: $pass) } }
                    PasswordRevealToggle(isRevealed: $reveal)
                }
            }
        }
    }
    .padding(Space.s18)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .screenFloor()
}
#endif
#endif
