import SwiftUI
import ParallaxJellyfin
import ParallaxCore

/// The single artwork-tile entry point: a `MediaThumbnail` (artwork + watched badge) with two
/// orthogonal, optional text slots —
///   - a `footer` drawn ON the image (caption + progress bar over the frosted ramp), and
///   - a `metadata` row BELOW the image (title + a two-ended detail line).
///
/// DESIGN LAW — *one text region per tile*: text lives on the image (footer caption) OR below it
/// (the metadata row), never both. The progress bar is a *glyph*, not text, and may accompany either
/// region — so a tile with a `metadata` row may still carry a BAR-ONLY footer (empty caption). The
/// compiler can't enforce this (both slots are just optionals): a caller passing `metadata != nil`
/// must itself pass a caption-less footer (`Footer.make(caption: nil, progress:)`). Jellyfin poster
/// grids pass both nil and render the thumbnail alone (the poster carries identity); Home shelves
/// fill the footer slot; the series season rows fill the metadata slot + a bar-only footer.
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
        maxImageRenderWidth: CGFloat? = nil,
        footer: MediaThumbnail.Footer? = nil,
        metadata: Metadata? = nil
    ) {
        Self.assertOneTextRegion(footer: footer, metadata: metadata)
        self.title = title
        self.metadata = metadata
        self.thumbnail = MediaThumbnail(
            jellyfin: imageRef, session: session,
            watched: watched, footer: footer, aspectRatio: aspectRatio, maxImageWidth: maxImageWidth,
            maxImageRenderWidth: maxImageRenderWidth,
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
        footer: MediaThumbnail.Footer? = nil,
        metadata: Metadata? = nil
    ) {
        Self.assertOneTextRegion(footer: footer, metadata: metadata)
        self.title = title
        self.metadata = metadata
        self.thumbnail = MediaThumbnail(
            artwork: artwork,
            watched: watched, footer: footer, aspectRatio: aspectRatio, maxImageWidth: maxImageWidth,
            accessibilityLabel: Self.accessibilityLabel(title: title, metadata: metadata)
        )
    }

    /// Gap between the thumbnail and its metadata row — shared with `MediaTileSkeleton` so the
    /// loading→loaded swap doesn't shift the grid.
    static let metadataGap: CGFloat = Space.s8

    /// Metadata-row line geometry, shared with `MediaTileSkeleton` (compiler-coupled now, not
    /// comment-coupled) so the skeleton reserves the exact rendered line boxes and the loading→loaded
    /// swap doesn't shift: the `.subheadline` title line, the inter-line gap, and the `.caption2`
    /// detail line. Heights are the rendered line boxes, not font points.
    static let metadataTitleStubHeight: CGFloat = 19
    static let metadataDetailStubHeight: CGFloat = 12
    static let metadataLineSpacing: CGFloat = 2

    var body: some View {
        // The tvOS focus highlight + zoom transition live on the thumbnail (inside MediaThumbnail),
        // not this stack — the poster lifts on focus while the metadata row stays as supporting
        // text beneath it. This contained form is always a SINGLE view, so callers may attach
        // `.task`/`contentShape`/etc. freely; a tvOS `.borderless` button label that wants the
        // native caption-avoidance nudge uses `lockup()` instead. `TileContainedStack` is the same
        // composition `TileLockup`'s iOS form renders, so the plain and `.lockup()` paths can't drift.
        TileContainedStack(artwork: thumbnail) {
            if let metadata {
                metadataRow(metadata)
            }
        }
    }

    /// The `.borderless` button-label form. On tvOS it emits the thumbnail and metadata row as
    /// SIBLING label children — the lockup layout slides the text out of the lifted image's way
    /// only when the text is its own label child; wrapped in the contained VStack it sat dead
    /// still and the focused still landed on the title (LockupTextSpikeScreen rows B/C,
    /// device-verified 2026-07). The style owns the thumbnail↔text gap and its focus motion;
    /// `metadataGap` remains the iOS/skeleton metric. iOS resolves to the contained form.
    ///
    /// Use ONLY as a Button label: the tvOS multi-view body is Group-transparent, so a modifier
    /// applied to a `Lockup` distributes onto EACH sibling (`.task` would run twice), and outside
    /// a lockup-managing button nothing supplies the thumbnail↔text gap.
    func lockup() -> Lockup { Lockup(tile: self) }

    /// Lockup whose artwork loads asynchronously (the SMB frame-grab tiles): the task rides ONLY
    /// the thumbnail sibling — attached to the whole tuple-transparent Lockup it would distribute
    /// onto every sibling and fetch twice (the reason `SMBThumbnailTile` was stuck with the
    /// contained form, costing it the tvOS caption nudge).
    func lockup(
        thumbnailTaskID: ItemID,
        thumbnailTask: @escaping @MainActor () async -> Void
    ) -> Lockup {
        Lockup(tile: self, thumbnailTaskID: thumbnailTaskID, thumbnailTask: thumbnailTask)
    }

    struct Lockup: View {
        let tile: MediaTile
        /// See `lockup(thumbnailTaskID:thumbnailTask:)` — a per-thumbnail async load, kept OFF the
        /// tuple so it runs once.
        var thumbnailTaskID: ItemID? = nil
        var thumbnailTask: (@MainActor () async -> Void)? = nil

        // The tvOS-sibling / iOS-contained split lives in `TileLockup`. The thumbnail and metadata
        // row already own their own accessibility (MediaThumbnail folds the label; `metadataRow` is
        // `.accessibilityHidden`), so `.childrenOwn` — the lockup adds no a11y. The optional load
        // rides the thumbnail sibling on tvOS (once) and the whole contained tile on iOS.
        var body: some View {
            TileLockup(
                artwork: tile.thumbnail,
                caption: {
                    if let metadata = tile.metadata {
                        tile.metadataRow(metadata)
                    }
                },
                taskID: thumbnailTaskID.map(AnyHashable.init),
                task: thumbnailTask
            )
        }
    }

    /// The one-text-region law, made observable: the compiler can't couple the two optional slots,
    /// so DEBUG builds trip here when a call site passes a captioned footer AND a metadata row —
    /// text on the image and below it at once, the exact duplication the law forbids.
    private static func assertOneTextRegion(footer: MediaThumbnail.Footer?, metadata: Metadata?) {
        assert(
            metadata == nil || (footer?.caption.isEmpty ?? true),
            "One text region per tile: a tile with a metadata row may only carry a bar-only footer (Footer.make(caption: nil, progress:))."
        )
    }

    /// The detail line folds into the thumbnail's single accessibility element ("Title, 1.4 GB,
    /// 1h 23m"); the visible row below is then hidden from VoiceOver so the tile reads as one
    /// element. An empty title drops out so a degenerate item never reads as ", 45 min".
    private static func accessibilityLabel(title: String, metadata: Metadata?) -> String {
        let parts = [title, metadata?.leading, metadata?.trailing]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func metadataRow(_ metadata: Metadata) -> some View {
        // Normalise empty strings to nil so a blank slot leaves no gap on the detail line.
        let leading = metadata.leading.flatMap { $0.isEmpty ? nil : $0 }
        let trailing = metadata.trailing.flatMap { $0.isEmpty ? nil : $0 }
        VStack(alignment: .leading, spacing: Self.metadataLineSpacing) {
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

/// The series season-row hybrid: landscape artwork with a BAR-ONLY footer (the one-text-region law —
/// no on-image caption) and the metadata row below carrying the indexed episode title + "min left".
/// First tile is mid-watch (progress band + "22 min left"); second is unwatched (nil progress ⇒ no
/// footer band at all, and the full runtime "45 min"). Explicit-height boxes like MediaThumbnail's
/// footer preview: the footer's bottom-pinning frame is vertically greedy, so a fixed 135pt image
/// row (16:9 at width 240) keeps the tile from stretching to fill the canvas — the real season shelf
/// gets this hug from `MetadataRow`'s enclosing scroll. Render on an iOS destination.
#Preview("Season row tile", traits: .sizeThatFitsLayout) {
    HStack(alignment: .top, spacing: 16) {
        MediaTile(
            title: "E3 · The One With the Embryos",
            artwork: .none,
            aspectRatio: MediaImage.landscape,
            footer: .make(caption: nil, progress: 0.4),
            metadata: .init(leading: "22 min left", trailing: nil)
        )
        .frame(width: 240, height: 178)
        MediaTile(
            title: "E4 · The One With the Screamer",
            artwork: .none,
            aspectRatio: MediaImage.landscape,
            footer: .make(caption: nil, progress: nil),
            metadata: .init(leading: "45 min", trailing: nil)
        )
        .frame(width: 240, height: 178)
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
