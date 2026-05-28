import SwiftUI
import ParallaxJellyfin

struct DetailHeader: View {
    let title: String
    let subtitle: String?
    let backdropRef: ImageRef?
    let session: Session

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Black floor under the image so a missing/slow backdrop renders
            // as solid black instead of letting whatever is behind the floating
            // sidebar bleed through.
            Color.black

            JellyfinImage(
                ref: backdropRef,
                kind: .backdrop(index: 0),
                session: session,
                maxWidth: 1280,
                aspectRatio: JellyfinImage.landscape
            )

            LinearGradient(
                colors: [Color.black.opacity(0.0), Color.black.opacity(0.85)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.largeTitle)
                    .bold()
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(20)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
    }
}
