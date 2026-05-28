import SwiftUI
import ParallaxJellyfin

struct DetailHeader: View {
    let title: String
    let subtitle: String?
    let backdropRef: ImageRef?
    let logoRef: ImageRef?
    let session: Session

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            JellyfinImage(
                ref: backdropRef,
                kind: .backdrop(index: 0),
                session: session,
                maxWidth: 1280
            )

            // Gradient overlay so text is readable on any backdrop.
            LinearGradient(
                colors: [Color.black.opacity(0.0), Color.black.opacity(0.75)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 8) {
                if logoRef != nil {
                    JellyfinImage(
                        ref: logoRef,
                        kind: .logo,
                        session: session,
                        maxWidth: 480
                    )
                    .frame(maxHeight: 90)
                    .frame(maxWidth: 280, alignment: .leading)
                } else {
                    Text(title)
                        .font(.largeTitle)
                        .bold()
                        .foregroundStyle(.white)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(20)
        }
    }
}
