import SwiftUI

/// Centered, secondary subtitle for the logged-out connect screens — sits under the brand mark in
/// each body (sign-in, Quick Connect, the source picker). Pulled out of the old combined brand header
/// so it travels with the sliding body while `BrandMark` stays put. Still connect-flow only, so it
/// keeps the `Auth` name (the brand mark, now used in Settings too, moved to `BrandMark`).
struct AuthSubtitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.authSubtitle)
            .foregroundStyle(Color.secondaryLabel)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}
