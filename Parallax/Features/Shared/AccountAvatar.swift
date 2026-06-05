import SwiftUI
import ParallaxJellyfin

/// Circular account glyph. Shows the Jellyfin user's profile photo when they have one,
/// falling back to a neutral `person` mark — never a lettered placeholder. Shared by the
/// sidebar footer, the compact nav-bar account button, and the settings header so the
/// avatar reads identically everywhere. Decorative: the enclosing control supplies the
/// VoiceOver label, so the glyph itself is hidden from accessibility.
struct AccountAvatar: View {
    let session: Session
    /// Base diameter scaled by Dynamic Type, so the avatar grows with the user's text
    /// size instead of staying pinned while the labels beside it grow. Fixed across
    /// screen *widths* on purpose — it's nav-bar / sidebar chrome, not content.
    @ScaledMetric private var size: CGFloat

    init(session: Session, size: CGFloat = 34) {
        self.session = session
        self._size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    var body: some View {
        ZStack {
            // Stays behind the photo while it loads and shows through on failure or when
            // the user has no image set.
            Circle()
                .fill(Color.fill)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.5, weight: .medium))
                        .foregroundStyle(Color.secondaryLabel)
                }
            if let imageURL {
                LazyImageRenderer(url: imageURL, session: session, contentMode: .fill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }

    /// Jellyfin profile-image URL, or nil when the user has no image (→ person fallback).
    /// Requests @3x the rendered size so the small thumbnail stays crisp.
    private var imageURL: URL? {
        guard let tag = session.user.primaryImageTag else { return nil }
        return ImageURLBuilder.userImageURL(
            serverURL: session.serverURL,
            userID: session.user.id,
            tag: tag,
            maxWidth: Int(size * 3)
        )
    }
}
