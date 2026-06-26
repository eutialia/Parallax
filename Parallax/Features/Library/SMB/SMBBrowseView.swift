import SwiftUI
import ParallaxCore
import ParallaxFileBrowse
import ParallaxJellyfin
#if DEBUG
import ParallaxPlayback  // preview-only: builds a real MediaArtworkProvider for the stub grid
#endif

/// Navigation value for one level of an SMB share browse. Drives the recursive
/// `.navigationDestination`, so drilling into a folder just pushes a new value with the child's
/// path. The lister/`SMBFileSource` is deliberately NOT carried here — an `AMSMB2Lister` is an
/// actor (not `Hashable`), so each `SMBBrowseView` rebuilds its own from `ref` in `.task` and
/// disconnects it on disappear.
struct SMBBrowsePath: Hashable {
    /// The owning server — supplies the host + credentials to build a lister for this level.
    let ref: SMBServerRef
    /// The share being browsed (the server can host many).
    let share: String
    /// Share-relative path of this level; empty = share root.
    let path: String
}

/// One level of an SMB share's folder browse: a grid of subfolders (drill in) above the level's
/// playable media (play). Folders push a child `SMBBrowsePath` (the destination recurses back into
/// this same view); media plays through the app's `PlaybackPresenter`, the same entry point the
/// library grid's SMB tiles use (`playback.playSMB(_:ref:)`).
///
/// Each level owns its connection: `.task` builds a lister via `deps.makeSMBLister(ref)` and an
/// `SMBFileSource(lister:host:share:root:"")`, then the view model lists `path.path`; `.onDisappear`
/// tears it down (`teardown()` cancels + disconnects). Empty `root` because the level's absolute
/// share-relative path is passed as the browse `path`, which replaces (never joins) `root`.
struct SMBBrowseView: View {
    let path: SMBBrowsePath

    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackPresenter.self) private var playback
    @Environment(\.appIdiom) private var idiom
    @State private var model: SMBBrowseViewModel?

    var body: some View {
        Group {
            if let model {
                content(model: model)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(levelTitle)
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Recurse: drilling into a folder pushes a child `SMBBrowsePath`, which lands back here a
        // level deeper. Registered on every level so the stack can keep descending.
        .navigationDestination(for: SMBBrowsePath.self) { SMBBrowseView(path: $0) }
        #if !os(tvOS)
        // iPhone/iPad carry the sort control in the nav bar's trailing edge. (tvOS instead rides it
        // in-content above the grid — toolbar items can't join the tvOS focus engine; see `sortHeader`.)
        // Mounted unconditionally so it doesn't blink in after the push settles; inert until the
        // per-level view model exists.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SMBBrowseSortButton(
                    field: model?.sortField ?? SMBBrowseSort.default.field,
                    direction: model?.sortDirection ?? SMBBrowseSort.default.direction,
                    isEnabled: model != nil,
                    onSelectField: { model?.sortField = $0 },
                    onSelectDirection: { model?.sortDirection = $0 }
                )
            }
        }
        #endif
        .screenFloor()
        // Lifecycle: drilling into a child folder triggers this level's `onDisappear`, disconnecting
        // the per-level lister and freeing the SMB connection while off-screen. On back-navigation
        // the `.task` guard (`model != nil`) intentionally skips a reload and shows the cached
        // listing — fast and stale-tolerant; each level owns an independent lister so the child
        // level is completely unaffected by this level's teardown/reconnect cycle.
        .task {
            guard model == nil else { return }
            let lister = await deps.makeSMBLister(path.ref)
            let source = SMBFileSource(lister: lister, host: path.ref.data.host, share: path.share, root: "")
            let vm = SMBBrowseViewModel(source: source, share: path.share, path: path.path)
            model = vm
            vm.load()
        }
        .onDisappear { model?.teardown() }
    }

    /// Inline title: the current folder's name (last path component), or the share name at the root.
    private var levelTitle: String {
        path.path.split(separator: "/").last.map(String.init) ?? path.share
    }

    @ViewBuilder
    private func content(model: SMBBrowseViewModel) -> some View {
        if model.isLoading, model.folders.isEmpty, model.media.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.error, model.folders.isEmpty, model.media.isEmpty {
            StatusStateView.failure("Couldn't open \(levelTitle)", message: error)
        } else if model.folders.isEmpty, model.media.isEmpty {
            StatusStateView(
                title: "Nothing Here",
                systemImage: "folder",
                message: "This folder has no subfolders or playable media."
            )
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    #if os(tvOS)
                    sortHeader(model: model)
                    #endif
                    SMBBrowseGrid(
                        folders: model.folders,
                        media: model.media,
                        ref: path.ref,
                        share: path.share,
                        parentPath: path.path,
                        artworkProvider: deps.mediaArtworkProvider,
                        onPlay: { playback.playSMB($0, ref: path.ref) }
                    )
                }
            }
            .contentMargins(.horizontal, AppLayout.contentHMargin(idiom: idiom), for: .scrollContent)
            .contentMargins(.vertical, idiom == .tv ? Space.s40 : Space.s12, for: .scrollContent)
        }
    }

    // MARK: - tvOS sort header

    #if os(tvOS)
    /// tvOS in-content sort control, centered above the grid: toolbar items can't join the tvOS
    /// focus engine, so Sort rides inside the focusable scroll (iPhone/iPad keep it in the nav bar).
    /// Mirrors `LibraryGridView.headerControls` in its lone-chip case — SMB browse has no genre, so
    /// the chip centers alone. `tvFocusSection` makes the full-width row one focus target so pressing
    /// Up from any poster column diverts to the chip; the 30pt bottom gap clears the first poster row's
    /// focus lift. The `@Bindable` lens lives only here, so iOS carries no unused binding.
    private func sortHeader(model: SMBBrowseViewModel) -> some View {
        @Bindable var model = model
        return SMBBrowseSortChip(field: $model.sortField, direction: $model.sortDirection)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, Space.s8)
            .padding(.bottom, Space.s30)
            .tvFocusSection()
    }
    #endif
}

/// The folders-then-media wall for one browse level. Standalone (plain inputs, no `deps`/network)
/// so it renders in a `#Preview` and stays the single place the two cell kinds + layout live.
/// Folders are compact `FolderBrowseCard`s wrapped in a `NavigationLink` to the child path; media use
/// the same `SMBThumbnailTile` the library grid uses, wrapped in a play button. Each kind is its own
/// titled section so the boundary reads as an intentional group break, not a ragged half-empty row.
struct SMBBrowseGrid: View {
    let folders: [SMBDirectoryEntry]
    let media: [Item]
    let ref: SMBServerRef
    let share: String
    /// Share-relative path of the level being shown — a child folder's path is `parentPath/name`
    /// (or just `name` at the root).
    let parentPath: String
    let artworkProvider: MediaArtworkProvider
    let onPlay: (Item) -> Void

    @Environment(\.appIdiom) private var idiom

    var body: some View {
        // Folders above media, each in its own titled section at the dense landscape column count
        // (4-up on iPad). The section header turns the folder→media boundary into a deliberate break
        // (an incomplete folder row otherwise just reads as ragged empty space).
        VStack(alignment: .leading, spacing: AppLayout.posterGridRowSpacing(idiom: idiom) + Space.s12) {
            if !folders.isEmpty {
                browseSection("Folders") {
                    LazyVGrid(columns: columns, spacing: AppLayout.posterGridRowSpacing(idiom: idiom)) {
                        ForEach(folders, id: \.self) { folder in
                            NavigationLink(value: childPath(folder.name)) {
                                FolderBrowseCard(name: folder.name)
                            }
                            .tvPosterButton()
                        }
                    }
                }
            }
            if !media.isEmpty {
                browseSection("Videos") {
                    LazyVGrid(columns: columns, spacing: AppLayout.posterGridRowSpacing(idiom: idiom)) {
                        ForEach(media) { item in
                            Button { onPlay(item) } label: {
                                SMBThumbnailTile(item: item, ref: ref, provider: artworkProvider, aspectRatio: MediaImage.landscape)
                            }
                            .tvPosterButton()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A titled group (Folders / Videos). Reuses the Settings section-header vocabulary
    /// (`.sectionHeader`, uppercase, secondary label) so the browse wall reads in the same voice as
    /// the rest of the app and the header sits flush above its grid's leading card.
    @ViewBuilder
    private func browseSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            Text(title)
                .font(.sectionHeader)
                .textCase(.uppercase)
                .foregroundStyle(Color.secondaryLabel)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private var columns: [GridItem] {
        posterGridColumns(
            fixedColumns: AppLayout.landscapeGridColumns(idiom: idiom),
            columnMinWidth: 0,   // unused: a fixed count is always supplied
            columnSpacing: AppLayout.posterGridColumnSpacing(idiom: idiom)
        )
    }

    private func childPath(_ name: String) -> SMBBrowsePath {
        let child = parentPath.isEmpty ? name : "\(parentPath)/\(name)"
        return SMBBrowsePath(ref: ref, share: share, path: child)
    }
}

/// A folder cell sized to match the media tiles in the same wall: a 16:9 glyph card (a folder symbol
/// on the neutral SMB fill) with the name beneath, mirroring `MediaTile`'s thumbnail-over-title
/// layout so subfolders and videos align column-for-column. The big `LibraryBannerCard` is reserved
/// for the handful of top-level library banners; a directory of season folders wants this denser
/// tile, not a wall of two-up banners.
private struct FolderBrowseCard: View {
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: MediaTile.metadataGap) {
            ZStack {
                Color.fill
                Image(systemName: "folder.fill")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(Color.secondaryLabel)
            }
            .aspectRatio(MediaImage.landscape, contentMode: .fit)
            .clipShape(.rect(cornerRadius: Radius.tile))
            // tvOS system highlight masked to the tile's corners — pairs with `.borderless` (tvPosterButton).
            .tvPosterHighlight(cornerRadius: Radius.tile)
            Text(name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.label)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Pin the whole VStack (glyph card + name + the gap between) as the tap target, matching
        // `SMBThumbnailTile` — without it only the opaque art + name glyphs are tappable, leaving the
        // inter-element gap and the trailing space beside a short name dead.
        .contentShape(.rect(cornerRadius: Radius.tile))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
    }
}

#if DEBUG
/// Stub-data host for the browse grid (no network, no `deps`): a directory of season folders + a
/// wall of episodes so the dense 4-up landscape layout (folders on top, then media), both cell
/// kinds, and the column density are all verifiable. Media tiles show the gray placeholder — the
/// real provider is wired but never resolves a frame-grab without an SMB connection. The
/// `appIdiom: .regular` injection forces the iPad column count (the "4-up not 2-up" fix).
private struct SMBBrowseGridPreview: View {
    private let ref = SMBServerRef(
        id: ServerID(rawValue: "preview"),
        data: SMBServerData(host: "nas.local", username: "guest", domain: "", shares: ["Media"])
    )
    private let folders: [SMBDirectoryEntry] = [
        SMBDirectoryEntry(name: "Winter 2024", isDirectory: true, size: 0, modifiedAt: nil),
        SMBDirectoryEntry(name: "Spring 2024", isDirectory: true, size: 0, modifiedAt: nil),
        SMBDirectoryEntry(name: "OVAs & Specials", isDirectory: true, size: 0, modifiedAt: nil),
        SMBDirectoryEntry(name: "Extras", isDirectory: true, size: 0, modifiedAt: nil),
        SMBDirectoryEntry(name: "Movies", isDirectory: true, size: 0, modifiedAt: nil),
    ]
    private let media: [Item] = [
        "The Grand Budapest Hotel (2014).mkv", "Sintel.2010.1080p.mp4", "Big Buck Bunny.webm",
        "Tears of Steel.mkv", "Cosmos Laundromat.mp4", "Spring.mkv", "Caminandes.webm",
    ].map { name in
        SMBFileSource.item(
            from: SMBDirectoryEntry(name: name, isDirectory: false, size: 1_500_000_000, modifiedAt: nil),
            share: "Media", in: "Anime"
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                SMBBrowseGrid(
                    folders: folders,
                    media: media,
                    ref: ref,
                    share: "Media",
                    parentPath: "Anime",
                    artworkProvider: MediaArtworkProvider(thumbnailer: VLCThumbnailer(), keychain: Keychain(service: "preview")),
                    onPlay: { _ in }
                )
                .padding(Space.s16)
            }
            .background(Color.background)
        }
        .environment(\.appIdiom, .regular)
    }
}

#Preview("SMB browse · folders + media", traits: .fixedLayout(width: 900, height: 760)) {
    SMBBrowseGridPreview()
}
#endif
