#if !os(tvOS)
import SwiftUI

/// One iOS credential field, drawn as a standalone capsule PILL — a leading glyph + the editor on a
/// flat `Color.fill` capsule. This is the same pill language as the settings rows and the tvOS
/// credential rows (`CredentialRowList`), replacing the old fused group-with-hairlines that read as a
/// squared-off block beside the app's capsules. Shared by `LoginView` and `SMBLoginView` so the two
/// sign-in forms can't drift apart (they previously duplicated the row/hairline/height scaffolding
/// verbatim). tvOS uses `CredentialRowList` instead — single-field editor screens, not inline pills.
struct CredentialFieldPill<Content: View>: View {
    let icon: String
    @ViewBuilder var content: Content

    /// Scales with Dynamic Type so the editor never clips, and matches the form CTA's 50pt height so
    /// the field stack and the Connect button below it read as one control family.
    @ScaledMetric(relativeTo: .headline) private var height: CGFloat = 50

    var body: some View {
        HStack(spacing: Space.s12) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(Color.tertiaryLabel)
            content
        }
        // Wider horizontal inset than the old 14pt rows: a capsule's rounded ends eat ~half the height
        // in curve, so the glyph + text need to clear it (the same reason the settings pills inset s26).
        .padding(.horizontal, Space.s22)
        .frame(height: height)
        .background(Color.fill, in: Capsule())
    }
}

/// The inter-pill gap for a credential form — one source so `LoginView` and `SMBLoginView` space their
/// field pills and LAN-discovered rows identically.
extension CGFloat {
    static let credentialPillGap = Space.s8
}

#if DEBUG
#Preview("Credential field pills") {
    @Previewable @State var server = "https://jellyfin.example.com"
    @Previewable @State var user = ""
    @Previewable @State var pass = "hunter2"
    @Previewable @State var reveal = false
    return VStack(spacing: Space.s8) {
        CredentialFieldPill(icon: "globe") {
            TextField("Server", text: $server)
        }
        CredentialFieldPill(icon: "person") {
            TextField("Username", text: $user)
        }
        CredentialFieldPill(icon: "lock") {
            HStack {
                Group { if reveal { TextField("Password", text: $pass) } else { SecureField("Password", text: $pass) } }
                Button(reveal ? "Hide" : "Show") { reveal.toggle() }
                    .font(.footnote).foregroundStyle(Color.secondaryLabel).buttonStyle(.borderless)
            }
        }
    }
    .padding()
    .background(Color.background)
}
#endif
#endif
