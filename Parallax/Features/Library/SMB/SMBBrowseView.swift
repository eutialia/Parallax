import SwiftUI
import ParallaxCore
import ParallaxFileBrowse
import ParallaxJellyfin
#if DEBUG
import ParallaxPlayback  // preview-only: builds a real MediaArtworkProvider for the stub grid
#endif

/// Navigation value for one level of an SMB share browse. Drilling into a folder just pushes a new
/// value with the child's path; `smbBrowseDestination()` below resolves it recursively. The
/// lister/`SMBFileSource` is deliberately NOT carried here — neither is `Hashable` — so each
/// `SMBBrowseView` rebuilds its own from `ref` in `.task`. Rebuilding is cheap: the lister only
/// borrows from the shared connection pool.
struct SMBBrowsePath: Hashable {
    /// The owning server — supplies the host + credentials to build a lister for this level.
    let ref: SMBServerRef
    /// The share being browsed (the server can host many).
    let share: String
    /// Share-relative path of this level; empty = share root.
    let path: String
}

extension View {
    /// The single `SMBBrowsePath` navigation-destination registration for a stack: drilling into a
    /// folder pushes a child `SMBBrowsePath`, and this one declaration resolves it no matter how
    /// many levels deep the push happens. Apply it ONCE, wrapping the share-root `SMBBrowseView` —
    /// never inside `SMBBrowseView` itself (see the comment on its `body`) or a second registration
    /// lands on the stack as soon as a folder is one level deep. Every PUSHED level drops the tab
    /// sidebar (`tvHidesTabSidebar()`); the root keeps it, since this call's own site is the root.
    func smbBrowseDestination() -> some View {
        navigationDestination(for: SMBBrowsePath.self) { SMBBrowseView(path: $0).tvHidesTabSidebar() }
    }
}

/// One level of an SMB share's folder browse: a grid of subfolders (drill in) above the level's
/// playable media (play). Folders push a child `SMBBrowsePath` (the destination recurses back into
/// this same view); media plays through the app's `PlaybackPresenter`, the same entry point the
/// library grid's SMB tiles use (`playback.playSMB(_:ref:)`).
///
/// Connections belong to the shared pool, not to a level: `.task` builds a lister via
/// `deps.makeSMBLister(ref)` and an `SMBFileSource(lister:host:share:root:"")`, then the view model
/// lists `path.path`. Every level of every share borrows the same warm connections, so a drill-in
/// costs no handshake and leaving a level tears nothing down — the pool ages idle connections out
/// on its own, and only ever while nobody is using them. It deliberately KEEPS one warm connection
/// per share indefinitely (not a leak: that survivor is what makes the next drill-in handshake-free
/// — see `SMBConnectionPool.reapIdle`). Empty `root` because the level's absolute share-relative
/// path is passed as the browse `path`, which replaces (never joins) `root`.
struct SMBBrowseView: View {
    let path: SMBBrowsePath

    @Environment(AppDependencies.self) private var deps
    @Environment(PlaybackPresenter.self) private var playback
    @Environment(\.appIdiom) private var idiom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: SMBBrowseViewModel?
    /// Highest media index the viewport-ahead prefetch window has covered; -1 = none yet. Monotonic
    /// per listing so scroll-back re-appearances don't re-hand items to the provider.
    @State private var prefetchedThrough = -1
    /// The `listingGeneration` the watermark belongs to. Checked SYNCHRONOUSLY in `prefetchWindow`
    /// (not via an async `.task` reset, which loses to re-materialized cells' onAppear and would
    /// leave a stale-high watermark suppressing the new listing's window).
    @State private var prefetchedGeneration = -1
    /// Set when the lister can't even be BUILT — there's no view model to carry an error yet.
    @State private var setupError: String?
    /// True when `setupError` is unrecoverable without re-adding the server (a confirmed-lost
    /// Keychain slot). A transient fault (`.unexpected` keychain read error) stays non-terminal
    /// so `.recoversFromOffline` may clear it and retry `openLevel()`.
    @State private var setupErrorIsTerminal = false
    /// True when `setupError` is a credential fault the user can fix here by re-entering the
    /// password (a lost Keychain slot). Drives the recovery button on the failure state.
    @State private var setupErrorOffersPasswordRecovery = false
    /// Drives the pushed password-recovery form. One level at a time can be in a failure state, so
    /// only one level's binding is ever live.
    @State private var isEnteringPassword = false
    /// Programmatic scroll handle for the wall (the iOS 18 `ScrollPosition` struct, NOT the legacy
    /// `scrollPosition(id:)` binding this replaces). The difference is the whole bug fix: a user
    /// scroll puts the struct into its user-driven mode and SwiftUI then never spontaneously
    /// re-applies an identity anchor — whereas the live two-way binding was treated as
    /// authoritative on every unrelated update, re-anchoring the wall to a tile the lazy grid had
    /// often ALREADY RECYCLED (fast fling leaves the anchor rows behind). That reconciliation
    /// fought the finger (the wall shifted up/down mid-scroll) and sometimes failed to locate the
    /// recycled anchor entirely (snap back to the top). The only write here is the explicit
    /// width-change restore below; see `SMBBrowseViewModel.visibleFolderIDs` for how the anchor
    /// identity is tracked.
    @State private var scrollPosition = ScrollPosition()

    var body: some View {
        Group {
            if let model {
                content(model: model)
            } else if let setupError {
                StatusStateView(
                    title: "Can't Open Share",
                    systemImage: "externaldrive.badge.xmark",
                    message: setupError,
                    action: setupErrorOffersPasswordRecovery ? passwordRecoveryAction : nil
                )
            } else {
                loadingSkeleton
            }
        }
        // tvOS deliberately carries NO in-content title, matching `LibraryGridView` (a tvOS
        // navigation title renders as in-content text that clips against the grid when the wall
        // scrolls). At the share ROOT the collapsed sidebar's pill names the surface; pushed folder
        // levels run unlabeled — `tvHidesTabSidebar()` drops that pill with the rest of the tab
        // chrome, a known trade against the broken-sidebar-over-push bug it exists to avoid. iOS
        // keeps the inline bar title (the current folder name) for drill-down orientation.
        #if !os(tvOS)
        .navigationTitle(levelTitle)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Recursion: drilling into a folder pushes a child `SMBBrowsePath`, which lands back here a
        // level deeper. NOT registered here — a `navigationDestination(for:)` only needs declaring
        // ONCE per `NavigationStack`, at any ancestor of the pushes; a deeper push still resolves
        // through that single ancestor declaration. Redeclaring it on every level (as this used to)
        // put a second `SMBBrowsePath` registration on the stack the moment a folder was one level
        // deep, which is exactly SwiftUI's "A navigationDestination... was declared earlier on the
        // stack" warning. The one declaration lives where the share root is first pushed —
        // `smbBrowseDestination()` below, applied at `libraryEntryDestination(for:)`'s `.smb` case.
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
        // In-place credential recovery, from both password-shaped dead ends on this screen (the
        // lost Keychain slot before the lister exists, and the server refusing the sign-in at the
        // share root). Pushed, not modal — it's a task within this browse, and the same idiom the
        // settings share list uses for the identical repair.
        .navigationDestination(isPresented: $isEnteringPassword) {
            SMBPasswordRecoveryView(id: path.ref.id, data: path.ref.data) {
                isEnteringPassword = false
                retryAfterPasswordRecovery()
            }
            .tvHidesTabSidebar()
        }
        // Lifecycle: on back-navigation the `.task` guard (`model != nil`) intentionally skips a
        // reload and shows the cached listing — fast and stale-tolerant. There is no matching
        // teardown: the level holds no connection, only a pooled borrower.
        .task {
            guard model == nil, setupError == nil else { return }
            await openLevel()
        }
        // Auto-recover a "Share Unavailable" / "Couldn't open" level when the network returns (or
        // the app foregrounds online) — re-lists this level. Gated on `isStalled` (errored AND
        // nothing listed) so a populated level isn't re-listed; a non-terminal setup failure
        // (transient keychain fault before the model existed) recovers by rebuilding the level.
        // `load()` is sync (spawns its own task); the discarded result is fine in this Void closure.
        .recoversFromOffline(isStalled: model?.isStalled ?? (setupError != nil && !setupErrorIsTerminal)) {
            if let model {
                model.load()
            } else {
                setupError = nil
                Task { await openLevel() }
            }
        }
        // After sleep every pooled socket is dead: flush idle corpses first, then re-list this
        // level with the current content still on screen. Flush-then-refresh so this level's own
        // re-list can't check out a connection that's already a corpse (checkout cold-connects when
        // nothing warm is idle). It only orders THIS call: on a stalled level `.recoversFromOffline`
        // fires its own `load()` on the same `.active` edge with no ordering against the flush, so
        // that listing may still borrow a pre-flush corpse — the pool's warm-corpse retry
        // (`PooledSMBLister.list`) absorbs it. Only the currently-visible top of the stack fires
        // (see `.refreshesOnForeground`).
        //
        // Disabled while a player is up: on iOS the player is an OVERLAY, so this level stays
        // mounted (no `onDisappear`) and a foreground return mid-playback would flush the pool and
        // re-list over the very uplink the stream is using. The artwork provider's `playbackActive`
        // hold covers thumbnail generation only — a directory listing is not gated by it.
        .refreshesOnForeground(isEnabled: !playback.isPlayerPresent) {
            await deps.flushSMBConnections()
            // `refresh()` marks its own start and finish from inside its task — it returns as soon
            // as that task is spawned, so a bracket here would only ever time the spawn.
            model?.refresh()
        }
    }

    /// The recovery affordance both password-shaped failure states offer: re-enter the saved
    /// password for this server without removing it.
    private var passwordRecoveryAction: StatusStateView.Action {
        StatusStateView.Action("Enter Password…") { isEnteringPassword = true }
    }

    /// After the password verified and was stored: rebuild the level from scratch. Deliberately NOT
    /// `model.load()` — an existing view model's lister was built with the OLD password (it's baked
    /// into the credentials the pool keys connections by), so re-listing through it would just be
    /// refused again. Dropping the model sends `openLevel()` back through the Keychain for the
    /// password that was just stored.
    private func retryAfterPasswordRecovery() {
        model = nil
        setupError = nil
        setupErrorOffersPasswordRecovery = false
        setupErrorIsTerminal = false
        Task { await openLevel() }
    }

    /// Builds this level's lister + view model and starts the first list. Failure before the model
    /// exists lands in `setupError`; only a confirmed-lost credential slot is terminal (no automatic
    /// retry helps — the user has to supply the password) — everything else stays recoverable.
    private func openLevel() async {
        do {
            let lister = try await deps.makeSMBLister(path.ref)
            // The factory awaits a Keychain read, so this level may already have been popped (or the
            // offline-recovery hook may have restarted it) by the time it returns — building a model
            // and starting a listing then costs a borrow nothing will look at.
            guard !Task.isCancelled else { return }
            let source = SMBFileSource(lister: lister, host: path.ref.data.host, share: path.share, root: "")
            let vm = SMBBrowseViewModel(source: source, share: path.share, path: path.path)
            model = vm
            vm.load()
        } catch {
            let appError = error as? AppError
            if case .auth(.credentialUnavailable) = appError {
                setupErrorIsTerminal = true
                setupErrorOffersPasswordRecovery = true
            } else {
                setupErrorIsTerminal = false
                setupErrorOffersPasswordRecovery = false
            }
            setupError = appError?.userMessage ?? "Couldn't open this share."
        }
    }

    /// Inline title: the current folder's name (last path component), or the share name at the root.
    private var levelTitle: String {
        path.path.split(separator: "/").last.map(String.init) ?? path.share
    }

    /// Whether a revalidate is allowed to dim + freeze this wall.
    ///
    /// Unlike `LibraryGridView` — whose revalidate follows a sort/filter the user just chose — the
    /// only trigger here is the INVOLUNTARY foreground wake re-list (a sort change goes through
    /// `load()` and the skeleton). On tvOS the modifier's `allowsHitTesting(false)` pulls focus off
    /// whatever poster the user was on and parks it on the sort chip, losing a deep scroll position
    /// for a refresh nobody asked for. So tvOS revalidates SILENTLY; iOS has no focus to lose and
    /// keeps the crossfade.
    #if os(tvOS)
    private static let dimsOnRevalidate = false
    #else
    private static let dimsOnRevalidate = true
    #endif

    /// Rows of thumbnails warmed BEYOND the tile that just appeared — a perception buffer, not the
    /// whole folder (explicit user policy: scroll landings should be warm, but a huge directory must
    /// not fetch wall-to-wall; un-approached items wait until the viewport nears them).
    private static let prefetchLookaheadRows = 12

    /// Viewport-ahead prefetch: when the media tile at `index` materialises in the lazy grid, hand
    /// the provider the next `prefetchLookaheadRows` rows' worth of items past the current watermark.
    /// Monotonic via `prefetchedThrough`, so each item is handed over once per listing; the provider
    /// dedupes any overlap (cache / pending / negative-cache) anyway. The tile's own `.task` covers
    /// `index` itself at visible priority.
    private func prefetchWindow(from index: Int, model: SMBBrowseViewModel) {
        // A fresh listing (load, re-sort) invalidates the watermark: indices reshuffled, so the
        // coverage bound belongs to a dead order. Reset SYNCHRONOUSLY here — this handler runs in
        // the same commit that materializes the new cells, so no onAppear can beat it.
        if prefetchedGeneration != model.listingGeneration {
            prefetchedGeneration = model.listingGeneration
            prefetchedThrough = -1
        }
        let lookahead = Self.prefetchLookaheadRows * AppLayout.landscapeGridColumns(idiom: idiom)
        let upper = min(index + lookahead, model.media.count - 1)
        let lower = max(prefetchedThrough + 1, index + 1)
        guard lower <= upper else { return }
        let slice = Array(model.media[lower...upper])
        prefetchedThrough = upper
        let sidecars = model.artwork
        Task {
            await deps.mediaArtworkProvider.prefetch(slice, ref: path.ref, sidecars: sidecars)
        }
    }

    @ViewBuilder
    private func content(model: SMBBrowseViewModel) -> some View {
        if model.isLoading, model.folders.isEmpty, model.media.isEmpty {
            loadingSkeleton
        } else if let error = model.error, model.folders.isEmpty, model.media.isEmpty {
            if model.errorIsSignInRefusal {
                // SIGN-IN refusal (libsmb2 EPERM — stale/lost stored password) at ANY depth: a
                // password can go stale server-side while the user is folders deep, and walking
                // back to the share root to find the repair is a maze. The share isn't gone, the
                // server rejected the session. Same recovery copy as the Settings share list so
                // both surfaces give one answer.
                StatusStateView(
                    title: "Sign-In Refused",
                    systemImage: "key.slash",
                    message: "\(path.ref.data.host) rejected the sign-in. Enter the password again to reconnect.",
                    action: passwordRecoveryAction
                )
            } else if path.path.isEmpty {
                // Share-root failure: the share itself wouldn't open — gone server-side (the same
                // orphan the Settings share list now surfaces as removable) or the server's
                // unreachable. A dedicated warning beats the generic per-folder error and points at
                // the recovery; deeper folders keep the plain "Couldn't open" with the raw reason.
                StatusStateView(
                    title: "Share Unavailable",
                    systemImage: "externaldrive.badge.xmark",
                    message: "The \(path.share) share isn’t available on \(path.ref.data.host). It may be offline, renamed, or no longer shared. If it’s gone for good, remove it from this server in Settings."
                )
            } else {
                StatusStateView.failure("Couldn't open \(levelTitle)", message: error)
            }
        } else if model.folders.isEmpty, model.media.isEmpty {
            StatusStateView(
                title: "Nothing Here",
                systemImage: "folder",
                message: "This folder has no subfolders or playable media."
            )
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    // The sort chip stays OUTSIDE `.staleWhileRevalidate` below — that modifier
                    // applies `.allowsHitTesting(false)` while refreshing, and a pushed tvOS level
                    // hides the tab sidebar, so trapping the chip too would leave the level with
                    // zero focusable elements for the length of the re-list (the tvOS empty-focus
                    // trap this scoping avoids; mirrors `LibraryGridView.gridScrollContent`, whose
                    // header controls sit outside its own `MediaGrid`-scoped modifier).
                    #if os(tvOS)
                    sortHeader(model: model)
                    #endif
                    SMBBrowseGrid(
                        folders: model.folders,
                        media: model.media,
                        artwork: model.artwork,
                        ref: path.ref,
                        share: path.share,
                        parentPath: path.path,
                        artworkProvider: deps.mediaArtworkProvider,
                        onMediaTileAppeared: { prefetchWindow(from: $0, model: model) },
                        onFoldersVisibilityChanged: { model.visibleFolderIDs = $0 },
                        onMediaVisibilityChanged: { model.visibleMediaIDs = $0 },
                        onPlay: { playback.playSMB($0, ref: path.ref) }
                    )
                    // Stale-while-revalidate dim → crossfade during a foreground re-list (shared
                    // with the library grid so the two never drift). Scoped to the grid, not the
                    // whole scroll subtree — see the comment on `sortHeader` above.
                    .staleWhileRevalidate(
                        isRefreshing: Self.dimsOnRevalidate && model.isRefreshing,
                        reduceMotion: reduceMotion
                    )
                }
            }
            // The share ROOT keeps the tvOS tab chrome, so it takes the root-chrome bypass to rest
            // at the same y as the chrome-less pushed levels — see `mediaWallContentMargins`.
            .mediaWallContentMargins(iosVertical: Space.s12, tvRootChromeBypass: path.path.isEmpty)
            // Programmatic scroll handle, not a live binding — see `scrollPosition` above for why
            // the legacy `scrollPosition(id:)` form caused mid-scroll jumps. The grids'
            // `.scrollTargetLayout()` + `onScrollTargetVisibilityChange` keep the topmost visible
            // tile's identity recorded on the view model; the modifier below re-anchors to it when
            // the scroll view's WIDTH changes: an iPhone landscape playback session reflows this
            // (covered) level at landscape width and back, and a bare point offset doesn't survive
            // the round trip — the wall came back scrolled to the top.
            .scrollPosition($scrollPosition)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { oldWidth, newWidth in
                guard oldWidth != newWidth, let anchor = model.scrollAnchorID else { return }
                scrollPosition.scrollTo(id: anchor)
            }
        }
    }

    /// The listing placeholder both loading branches show (building the lister, and the first
    /// list of a built one) — the wall's shape instead of a bare spinner. Same margins + root
    /// bypass as the loaded wall so the arrival lands where the skeleton stood. The skeleton
    /// itself carries the tvOS focus target (Menu mid-list must pop, not suspend the app; the
    /// error/empty branches get theirs via StatusStateView).
    private var loadingSkeleton: some View {
        ScrollView {
            SMBBrowseLoadingSkeleton()
        }
        .scrollDisabled(true)
        .mediaWallContentMargins(iosVertical: Space.s12, tvRootChromeBypass: path.path.isEmpty)
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
            // The shared chip-row tokens (not raw Space values): `SMBBrowseLoadingSkeleton`'s
            // chip stub reads the same pair, so the skeleton→chip swap stays coupled by compiler.
            .padding(.top, AppLayout.chipRowTopPadding)
            .padding(.bottom, AppLayout.chipRowBottomClearance)
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
    /// Strict per-item sidecar-image matches (keyed by `ItemID`); threaded into each tile so the
    /// provider prefers a real poster over a frame-grab. Only matched items appear.
    var artwork: [ItemID: SMBDirectoryEntry] = [:]
    let ref: SMBServerRef
    let share: String
    /// Share-relative path of the level being shown — a child folder's path is `parentPath/name`
    /// (or just `name` at the root).
    let parentPath: String
    let artworkProvider: MediaArtworkProvider
    /// Fired when a media tile materialises in the lazy grid (its index in `media`) — drives the
    /// owner's viewport-ahead prefetch window. Optional so previews need no prefetch plumbing.
    var onMediaTileAppeared: ((Int) -> Void)? = nil
    /// Visible-tile identity reports from `onScrollTargetVisibilityChange`, in layout order
    /// (topmost first): the raw material for the width-change scroll anchor (see the owner's
    /// `.scrollPosition`). Optional so previews need none of that plumbing.
    var onFoldersVisibilityChanged: (([SMBDirectoryEntry]) -> Void)? = nil
    var onMediaVisibilityChanged: (([ItemID]) -> Void)? = nil
    let onPlay: (Item) -> Void

    @Environment(\.appIdiom) private var idiom

    var body: some View {
        // Folders above media, each in its own titled section at the dense landscape column count
        // (4-up on iPad). The section header turns the folder→media boundary into a deliberate break
        // (an incomplete folder row otherwise just reads as ragged empty space).
        VStack(alignment: .leading, spacing: AppLayout.browseSectionGap(idiom: idiom)) {
            if !folders.isEmpty {
                browseSection("Folders") {
                    LazyVGrid(columns: columns, spacing: AppLayout.posterGridRowSpacing(idiom: idiom)) {
                        ForEach(folders, id: \.self) { folder in
                            NavigationLink(value: childPath(folder.name)) {
                                FolderBrowseCard(name: folder.name)
                            }
                            // `pressableTileButton()`: iOS press-scale to match the same bounded,
                            // glyph-led tile idiom as the library grid; tvOS forwards to
                            // `tvPosterButton()`, unchanged.
                            .pressableTileButton()
                        }
                    }
                    // Each tile is a scroll target so `onScrollTargetVisibilityChange` below can
                    // report the topmost visible one for the width-change scroll anchor.
                    .scrollTargetLayout()
                    .onScrollTargetVisibilityChange(idType: SMBDirectoryEntry.self, threshold: 0) {
                        onFoldersVisibilityChanged?($0)
                    }
                    // Each section grid is its own tvOS focus section so entering it (Down from
                    // the centered sort chip, or across the Folders→Videos boundary) diverts to
                    // the NEAREST tile. Without it the engine aims at the middle column, and a
                    // row sparser than that column index leaves Down with no candidate — focus
                    // strands on the chip. Mirrors the same modifier on `MediaGrid`.
                    .tvFocusSection()
                }
            }
            if !media.isEmpty {
                browseSection("Videos") {
                    LazyVGrid(columns: columns, spacing: AppLayout.posterGridRowSpacing(idiom: idiom)) {
                        // Indexed so a cell's materialisation can report its position for the
                        // prefetch window; identity stays the item's own id (not the offset), so
                        // moves under a re-sort animate as moves, not wholesale replacements.
                        ForEach(Array(media.enumerated()), id: \.element.id) { index, item in
                            Button { onPlay(item) } label: {
                                // `.lockup()`: sibling label children on tvOS so the filename
                                // nudges clear of the focus lift (contained on iOS).
                                SMBThumbnailTile(item: item, ref: ref, provider: artworkProvider, sidecar: artwork[item.id], aspectRatio: MediaImage.landscape)
                                    .lockup()
                            }
                            // Same artwork-tile idiom as the library grid/search results — press-scale
                            // on iOS; tvOS forwards to `tvPosterButton()`, unchanged.
                            .pressableTileButton()
                            // `onAppear` on a lazy-grid cell fires at materialisation (viewport-near),
                            // which is exactly the "the user is approaching this row" signal the
                            // prefetch window keys on.
                            .onAppear { onMediaTileAppeared?(index) }
                        }
                    }
                    .scrollTargetLayout()
                    .onScrollTargetVisibilityChange(idType: ItemID.self, threshold: 0) {
                        onMediaVisibilityChanged?($0)
                    }
                    // Same nearest-tile entry divert as the Folders grid above.
                    .tvFocusSection()
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
        // The tvOS-sibling / iOS-contained split lives in `TileLockup`; `.flatten(label:)` reproduces
        // this card's a11y exactly. tvOS: the name is its OWN label child (the `.borderless` lockup
        // only slides it clear of the lifted card when it is — contained, the focused card landed on
        // the name, the same suppression the search tiles and `SMBThumbnailTile.Lockup` fixed). iOS:
        // the whole tile (glyph card + name + the gap between) collapses to one labelled element with
        // the tap shape, so the inter-element gap and the space beside a short name aren't dead.
        TileLockup(
            artwork: glyphCard,
            caption: { nameLabel },
            accessibility: .flatten(label: name),
            iOSContentShapeRadius: Radius.tile
        )
    }

    private var glyphCard: some View {
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
    }

    private var nameLabel: some View {
        Text(name)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.label)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    artworkProvider: MediaArtworkProvider(
                        thumbnailer: VLCThumbnailer(),
                        avThumbnailer: AVThumbnailer(),
                        serverStore: ServerStore(
                            settings: SettingsStore(defaults: .standard),
                            keychain: Keychain(service: "preview")
                        )
                    ),
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

/// The share-root failure state (the #1 complement): opening a share that's gone server-side or
/// offline lands the library view here instead of a generic "Couldn't open" — same StatusStateView
/// the no-Home / no-network states use, with the recovery hint pointing back at Settings.
#Preview("SMB share unavailable", traits: .fixedLayout(width: 640, height: 520)) {
    StatusStateView(
        title: "Share Unavailable",
        systemImage: "externaldrive.badge.xmark",
        message: "The Media share isn’t available on nas.local. It may be offline, renamed, or no longer shared. If it’s gone for good, remove it from this server in Settings."
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.background)
    .preferredColorScheme(.dark)
}
#endif
