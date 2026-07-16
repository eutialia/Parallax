import SwiftUI
import ParallaxJellyfin
import ParallaxCore

/// A library grid cell: a `MediaThumbnail` (artwork + watched badge) with an *optional* metadata
/// row underneath — the filename + duration the wider 16:9 SMB tiles have room for. Jellyfin poster
/// grids pass `metadata: nil` and render the thumbnail alone (the poster carries identity). The
/// footer-bearing shelves use `MediaThumbnail` directly, not this.
struct MediaTile: View {
    /// The optional detail row under the thumbnail. Line one is the tile's `title` (one label
    /// source, no duplication); line two is a two-ended detail line — `leading` hugs the left edge,
    /// `trailing` the right. For SMB that's the file size on the left and the duration on the right,
    /// so both show at once and neither replaces the other (the duration just fills in on the right
    /// once the frame-grab resolves it). A non-nil value renders the row; nil hides it (Jellyfin
    /// posters carry identity unaided).
    struct Metadata: Equatable {
        let leading: String?
        let trailing: String?
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

    /// The detail line folds into the thumbnail's single accessibility element ("Title, 1.4 GB,
    /// 1h 23m"); the visible row below is then hidden from VoiceOver so the tile reads as one element.
    private static func accessibilityLabel(title: String, metadata: Metadata?) -> String {
        let details = [metadata?.leading, metadata?.trailing]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return ([title] + details).joined(separator: ", ")
    }

    @ViewBuilder
    private func metadataRow(_ metadata: Metadata) -> some View {
        // Normalise empty strings to nil so a blank slot leaves no gap on the detail line.
        let leading = metadata.leading.flatMap { $0.isEmpty ? nil : $0 }
        let trailing = metadata.trailing.flatMap { $0.isEmpty ? nil : $0 }
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.label)
                .lineLimit(1)
            if leading != nil || trailing != nil {
                HStack(spacing: Space.s8) {
                    if let leading {
                        Text(leading).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let trailing {
                        // The trailing slot holds short fixed facts (duration, "22 min left");
                        // under compression the leading text truncates, this never does.
                        Text(trailing).lineLimit(1).layoutPriority(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(Color.secondaryLabel)
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
    let session = Session.preview
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

/// The SMB landscape tile with its metadata row: filename on top, then file size (leading) and
/// duration (trailing) beneath, under a 16:9 frame-grab placeholder. Second tile is the cached/old
/// case — size only, no duration resolved yet.
#Preview("SMB metadata row", traits: .sizeThatFitsLayout) {
    HStack(spacing: 16) {
        MediaTile(
            title: "The Grand Budapest Hotel (2014)",
            artwork: .none,
            aspectRatio: MediaImage.landscape,
            metadata: .init(leading: "1.4 GB", trailing: "1h 39m")
        )
        .frame(width: 280)
        MediaTile(
            title: "Sintel.2010.1080p",
            artwork: .none,
            watched: .inProgress(0.3),
            aspectRatio: MediaImage.landscape,
            metadata: .init(leading: "2.1 GB", trailing: nil)
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
            metadata: .init(leading: "1.4 GB", trailing: "1h 39m")
        )
        .frame(width: 280)
    }
    .padding()
    .background(Color.background)
}
#endif
