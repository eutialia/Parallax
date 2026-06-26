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

    /// Inline title: the current folder's name, or the share name at the root.
    private var levelTitle: String {
        pathComponents.last ?? path.share
    }

    private var pathComponents: [String] {
        path.path.isEmpty ? [] : path.path.split(separator: "/").map(String.init)
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
                    breadcrumb
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

    // MARK: - Breadcrumb

    /// Share ⇄ path-component trail. Read-only — the nav stack owns back-navigation (swipe /
    /// back button), so the segments are labels, not tappable jumps.
    private var breadcrumb: some View {
        HStack(spacing: Space.s8) {
            Image(systemName: "externaldrive.badge.wifi")
                .font(.caption)
                .foregroundStyle(Color.tertiaryLabel)
            breadcrumbSegment(path.share, isCurrent: pathComponents.isEmpty)
            ForEach(Array(pathComponents.enumerated()), id: \.offset) { index, component in
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.tertiaryLabel)
                breadcrumbSegment(component, isCurrent: index == pathComponents.count - 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.s8)
        .padding(.bottom, Space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func breadcrumbSegment(_ label: String, isCurrent: Bool) -> some View {
        Text(label)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(isCurrent ? Color.label : Color.secondaryLabel)
            .lineLimit(1)
    }
}

/// The folders-then-media wall for one browse level. Standalone (plain inputs, no `deps`/network)
/// so it renders in a `#Preview` and stays the single place the two cell kinds + layout live.
/// Folders use the shared `LibraryBannerCard` chrome wrapped in a `NavigationLink` to the child
/// path; media use the same `SMBThumbnailTile` the library grid uses, wrapped in a play button.
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
        LazyVGrid(columns: columns, spacing: AppLayout.libraryListSpacing(idiom: idiom)) {
            // Folders first — they're the structure you navigate; media is the level's leaves.
            ForEach(folders, id: \.self) { folder in
                NavigationLink(value: childPath(folder.name)) {
                    FolderBrowseCard(name: folder.name)
                }
                .tvPosterButton()
            }
            ForEach(media) { item in
                Button { onPlay(item) } label: {
                    SMBThumbnailTile(item: item, ref: ref, provider: artworkProvider, aspectRatio: MediaImage.landscape)
                }
                .tvPosterButton()
            }
        }
    }

    private var columns: [GridItem] {
        let count = AppLayout.libraryListColumns(idiom: idiom)
        let spacing = AppLayout.libraryListSpacing(idiom: idiom)
        return Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: count)
    }

    private func childPath(_ name: String) -> SMBBrowsePath {
        let child = parentPath.isEmpty ? name : "\(parentPath)/\(name)"
        return SMBBrowsePath(ref: ref, share: share, path: child)
    }
}

/// A folder cell: the shared 16:9 `LibraryBannerCard` chrome with a network-folder glyph and the
/// folder name set in text (no server art, like the SMB library card), so a browsed folder reads as
/// the same family as the library banners it sits under.
private struct FolderBrowseCard: View {
    let name: String

    var body: some View {
        LibraryBannerCard(
            chipGlyph: "folder.fill",
            displayName: name,
            accessibilityName: name,
            watermark: ("externaldrive.connected.to.line.below.fill", 92)
        ) {
            Rectangle().fill(Color.fill)
        }
    }
}

#if DEBUG
/// Stub-data host for the browse grid (no network, no `deps`): ~3 folders + ~3 media so the
/// folders-then-media wall and both cell kinds render. Media tiles show the gray placeholder — the
/// real provider is wired but never resolves a frame-grab without an SMB connection. Stored as a
/// view (not a `let`-then-`return` preview closure) so the macro's ViewBuilder accepts it.
private struct SMBBrowseGridPreview: View {
    private let ref = SMBServerRef(
        id: ServerID(rawValue: "preview"),
        data: SMBServerData(host: "nas.local", username: "guest", domain: "", shares: ["Media"])
    )
    private let folders: [SMBDirectoryEntry] = [
        SMBDirectoryEntry(name: "Winter 2024", isDirectory: true, size: 0, modifiedAt: nil),
        SMBDirectoryEntry(name: "Spring 2024", isDirectory: true, size: 0, modifiedAt: nil),
        SMBDirectoryEntry(name: "OVAs & Specials", isDirectory: true, size: 0, modifiedAt: nil),
    ]
    private let media: [Item] = [
        SMBFileSource.item(from: SMBDirectoryEntry(name: "The Grand Budapest Hotel (2014).mkv", isDirectory: false, size: 1_500_000_000, modifiedAt: nil), share: "Media", in: "Anime"),
        SMBFileSource.item(from: SMBDirectoryEntry(name: "Sintel.2010.1080p.mp4", isDirectory: false, size: 2_100_000_000, modifiedAt: nil), share: "Media", in: "Anime"),
        SMBFileSource.item(from: SMBDirectoryEntry(name: "Big Buck Bunny.webm", isDirectory: false, size: 900_000_000, modifiedAt: nil), share: "Media", in: "Anime"),
    ]

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
    }
}

#Preview("SMB browse · folders + media", traits: .fixedLayout(width: 900, height: 760)) {
    SMBBrowseGridPreview()
}
#endif
