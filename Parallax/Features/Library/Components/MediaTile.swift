import SwiftUI
import ParallaxJellyfin

struct MediaTile: View {
    let title: String
    let subtitle: String?
    let imageRef: ImageRef?
    let imageKind: ImageKind
    let session: Session
    let progress: Double?   // 0.0–1.0; nil hides the bar
    let aspectRatio: CGFloat
    let maxImageWidth: Int

    init(
        title: String,
        subtitle: String?,
        imageRef: ImageRef?,
        imageKind: ImageKind,
        session: Session,
        progress: Double?,
        aspectRatio: CGFloat = JellyfinImage.poster,
        maxImageWidth: Int = 600
    ) {
        self.title = title
        self.subtitle = subtitle
        self.imageRef = imageRef
        self.imageKind = imageKind
        self.session = session
        self.progress = progress
        self.aspectRatio = aspectRatio
        self.maxImageWidth = maxImageWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                JellyfinImage(
                    ref: imageRef,
                    kind: imageKind,
                    session: session,
                    maxWidth: maxImageWidth,
                    aspectRatio: aspectRatio
                )
                .clipShape(.rect(cornerRadius: 8))

                if let progress, progress > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.25))   // track (over artwork)
                            Rectangle()
                                .fill(Color.white)                        // played portion — monochrome
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
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Always render the subtitle line (empty when absent) and reserve
            // both lines' height so every tile is identical — otherwise mixed
            // 1-/2-line titles and present/absent subtitles make a row's (and
            // grid's) thumbnails misalign (smoke-test #6/#7).
            Text(subtitle ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
