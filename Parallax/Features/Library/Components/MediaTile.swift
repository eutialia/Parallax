import SwiftUI
import ParallaxJellyfin
import ParallaxCore

/// A library grid cell: a `MediaThumbnail` (artwork + watched badge) with an *optional* metadata
/// row underneath — the filename + duration the wider 16:9 SMB tiles have room for. Jellyfin poster
/// grids pass `metadata: nil` and render the thumbnail alone (the poster carries identity). The
/// footer-bearing shelves use `MediaThumbnail` directly, not this.
struct MediaTile: View {
    /// The optional text row under the thumbnail. Its primary line is the tile's `title` (one label
    /// source, no duplication); this adds the supporting `secondary` line — duration, falling back
    /// to file size for SMB. A non-nil value renders the row; nil hides it (Jellyfin posters carry
    /// identity unaided).
    struct Metadata: Equatable {
        let secondary: String?
    }

    let title: String
    let metadata: Metadata?
    /// Built once at init: MediaTile is just this thumbnail plus the metadata row, so it stores the
    /// constructed `MediaThumbnail` instead of re-deriving an artwork enum that mirrors the one
    /// MediaThumbnail already owns.
    private let thumbnail: MediaThumbnail

    init(
        title: String,
        imageRef: ImageRef?,
        session: Session,
        watched: MediaThumbnail.WatchedStatus = .none,
        aspectRatio: CGFloat = MediaImage.poster,
        maxImageWidth: Int = 600,
        metadata: Metadata? = nil
    ) {
        self.title = title
        self.metadata = metadata
        self.thumbnail = MediaThumbnail(
            jellyfin: imageRef, session: session,
            watched: watched, aspectRatio: aspectRatio, maxImageWidth: maxImageWidth,
            accessibilityLabel: Self.accessibilityLabel(title: title, metadata: metadata)
        )
    }

    /// Source-neutral tile for non-Jellyfin items (SMB): a local thumbnail or the placeholder, with
    /// the same chrome as the Jellyfin tile and the metadata row the SMB grid populates.
    init(
        title: String,
        artwork: ArtworkSource,
        watched: MediaThumbnail.WatchedStatus = .none,
        aspectRatio: CGFloat = MediaImage.poster,
        maxImageWidth: Int = 600,
        metadata: Metadata? = nil
    ) {
        self.title = title
        self.metadata = metadata
        self.thumbnail = MediaThumbnail(
            artwork: artwork,
            watched: watched, aspectRatio: aspectRatio, maxImageWidth: maxImageWidth,
            accessibilityLabel: Self.accessibilityLabel(title: title, metadata: metadata)
        )
    }

    /// Gap between the thumbnail and its metadata row — shared with `MediaTileSkeleton` so the
    /// loading→loaded swap doesn't shift the grid.
    static let metadataGap: CGFloat = Space.s8

    var body: some View {
        // The tvOS focus highlight + zoom transition live on the thumbnail (inside MediaThumbnail),
        // not this VStack — the poster lifts on focus while the metadata row stays as supporting
        // text beneath it. SMB is iOS-first, where there's no focus lift, so the artwork-scoped
        // highlight only matters if SMB grids ever reach tvOS.
        VStack(alignment: .leading, spacing: Self.metadataGap) {
            thumbnail
            if let metadata {
                metadataRow(metadata)
            }
        }
    }

    /// The secondary line folds into the thumbnail's single accessibility element ("Title, 1h 23m");
    /// the visible row below is then hidden from VoiceOver so the tile reads as one element.
    private static func accessibilityLabel(title: String, metadata: Metadata?) -> String {
        guard let secondary = metadata?.secondary, !secondary.isEmpty else { return title }
        return "\(title), \(secondary)"
    }

    @ViewBuilder
    private func metadataRow(_ metadata: Metadata) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.label)
                .lineLimit(1)
            if let secondary = metadata.secondary, !secondary.isEmpty {
                Text(secondary)
                    .font(.caption2)
                    .foregroundStyle(Color.secondaryLabel)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}

#if DEBUG
/// Badge legibility on the placeholder field (worst case: a light poster — the hairline ring is
/// what separates the disc there) and the progress ring at the tricky fractions: barely started
/// (floored arc), the half mark, and almost-done next to the full check it morphs into.
#Preview("Watched badge", traits: .sizeThatFitsLayout) {
    let session = Session(
        id: ServerID(rawValue: "preview"),
        data: JellyfinServerData(
            serverURL: URL(string: "https://preview.invalid")!,
            serverName: "Preview",
            user: UserSnapshot(id: "u1", name: "preview", serverLastUpdatedAt: nil)
        ),
        accessToken: "preview"
    )
    return HStack(spacing: 16) {
        MediaTile(title: "Just started", imageRef: nil, session: session, watched: .inProgress(0.02))
            .frame(width: 140)
        MediaTile(title: "Halfway", imageRef: nil, session: session, watched: .inProgress(0.5))
            .frame(width: 140)
        MediaTile(title: "Almost done", imageRef: nil, session: session, watched: .inProgress(0.92))
            .frame(width: 140)
        MediaTile(title: "Watched", imageRef: nil, session: session, watched: .watched)
            .frame(width: 140)
        MediaTile(title: "Unwatched", imageRef: nil, session: session)
            .frame(width: 140)
    }
    .padding()
    .background(Color.background)
}

/// The SMB landscape tile with its metadata row: filename on top, duration (or the file-size
/// fallback) beneath, under a 16:9 frame-grab placeholder.
#Preview("SMB metadata row", traits: .sizeThatFitsLayout) {
    HStack(spacing: 16) {
        MediaTile(
            title: "The Grand Budapest Hotel (2014)",
            artwork: .none,
            aspectRatio: MediaImage.landscape,
            metadata: .init(secondary: "1h 39m")
        )
        .frame(width: 280)
        MediaTile(
            title: "Sintel.2010.1080p",
            artwork: .none,
            watched: .inProgress(0.3),
            aspectRatio: MediaImage.landscape,
            metadata: .init(secondary: "1.4 GB")
        )
        .frame(width: 280)
    }
    .padding()
    .background(Color.background)
}

/// Shift-free check for the SMB grid: the skeleton's reserved metadata band (left) must match the
/// loaded `MediaTile.metadataRow` height (right) so the load→loaded swap doesn't jump. Render on an
/// iOS destination and confirm the thumbnail bottoms and the text bands below them line up.
#Preview("SMB skeleton ↔ loaded parity", traits: .sizeThatFitsLayout) {
    HStack(alignment: .top, spacing: 16) {
        MediaTileSkeleton(aspectRatio: MediaImage.landscape, showsMetadata: true)
            .frame(width: 280)
        MediaTile(
            title: "The Grand Budapest Hotel (2014)",
            artwork: .none,
            aspectRatio: MediaImage.landscape,
            metadata: .init(secondary: "1h 39m")
        )
        .frame(width: 280)
    }
    .padding()
    .background(Color.background)
}
#endif
