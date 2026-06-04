import SwiftUI

/// Brand block shared by the sign-in and Quick Connect cards: a 64pt rounded tile holding
/// an SF Symbol, a large title, and a centered subtitle. Keeps the two auth screens
/// structurally identical so the header can't drift between them.
struct AuthBrandHeader: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: Space.s12) {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.label)
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: icon)
                        .scaledFont(30, relativeTo: .title, weight: .semibold)
                        .foregroundStyle(Color.background)
                }
            Text(title)
                .scaledFont(30, relativeTo: .title, weight: .bold)
                .foregroundStyle(Color.label)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(Color.secondaryLabel)
                .multilineTextAlignment(.center)
        }
    }
}
