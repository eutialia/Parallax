import SwiftUI
import ParallaxJellyfin

struct MediaTile: View {
    let title: String
    let subtitle: String?
    let imageRef: ImageRef?
    let imageKind: ImageKind
    let session: Session
    let progress: Double?   // 0.0–1.0; nil hides the bar

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                JellyfinImage(
                    ref: imageRef,
                    kind: imageKind,
                    session: session,
                    maxWidth: 320
                )
                .clipShape(.rect(cornerRadius: 8))

                if let progress, progress > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.black.opacity(0.5))
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 4)
                    .clipShape(.rect(cornerRadius: 2))
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                }
            }
            Text(title)
                .font(.caption)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
