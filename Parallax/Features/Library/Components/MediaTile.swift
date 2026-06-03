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
    var badges: [String]

    init(
        title: String,
        subtitle: String?,
        imageRef: ImageRef?,
        imageKind: ImageKind,
        session: Session,
        progress: Double?,
        aspectRatio: CGFloat = JellyfinImage.poster,
        maxImageWidth: Int = 600,
        badges: [String] = []
    ) {
        self.title = title
        self.subtitle = subtitle
        self.imageRef = imageRef
        self.imageKind = imageKind
        self.session = session
        self.progress = progress
        self.aspectRatio = aspectRatio
        self.maxImageWidth = maxImageWidth
        self.badges = badges
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
                .clipShape(.rect(cornerRadius: Radius.tile))

                if let progress, progress > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            // Dark track + white fill reads on any artwork in both
                            // appearances; the handoff's white-on-scrim treatment
                            // arrives with the MediaTile redesign (P3).
                            Rectangle().fill(Color.black.opacity(0.5))    // track
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

                if !badges.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(badges, id: \.self) { badge in
                            Text(badge)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.black.opacity(0.55), in: Capsule())
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
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
