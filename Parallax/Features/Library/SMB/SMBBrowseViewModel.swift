import Observation
import ParallaxCore
import ParallaxFileBrowse
import ParallaxJellyfin

/// Backs one level of `SMBBrowseView`: lists a single directory of a share into name-sorted
/// subfolders (drill targets) and playable media. One view model per browsed level — each
/// `SMBBrowseView` builds its own lister/`SMBFileSource` (a lister can't ride the `Hashable` nav
/// value). The lister is a thin, stateless borrower of the shared connection pool, so a level owns
/// no connection and has nothing to tear down.
///
/// **Leaving a level does NOT cancel its listing, on purpose.** There is no `deinit` teardown and no
/// `onDisappear` hook: a listing that is cancelled mid-flight leaves a native call the pool cannot
/// reuse the connection under, so the pooled lister CONDEMNS it — parked alive until that call
/// returns, and never handed to another borrower. Cancelling on every back-navigation would
/// therefore burn a warm connection each time. Letting the abandoned load finish instead returns the
/// connection to the pool; it costs one bounded listing (the lister's hard ceiling caps it) plus
/// this model and its `SMBFileSource` staying alive that long. Its writes DO land — and that is the
/// point: coming back to the level finds the listing already there instead of an empty wall,
/// because the view rebuilds against this same model.
///
/// Loading cancels any in-flight task before starting a new one; a stale-guard on the current
/// path ensures a slow, cancelled load can't overwrite the live directory. The level's path is
/// fixed for the model's lifetime, so the guard collapses to the cancellation check — but it's
/// kept explicit so the pattern remains readable. That cancel-on-reload has a price worth naming:
/// each re-sort abandons the running listing's connection to the graveyard, so a burst of sort
/// changes burns a warm connection apiece. Accepted — a re-sort is deliberate and rare, and the
/// alternative (reusing a socket mid-response) is the crash this layer exists to avoid. Failures map
/// through `SMBFileSource.mapListError` to the same `AppError` `userMessage` the Jellyfin grid
/// surfaces (`LibraryGridViewModel`), so SMB and Jellyfin errors read in one voice.
/// The identity-anchored scroll target for an SMB browse wall (see `SMBBrowseViewModel`
/// `.scrollAnchorID`). File scope and explicitly `nonisolated` — the project defaults to
/// MainActor isolation, and a main-actor-isolated `Hashable` conformance can't satisfy the
/// `Sendable` bound of `scrollTo(id:)`.
nonisolated enum SMBBrowseScrollAnchor: Hashable, Sendable {
    case folder(SMBDirectoryEntry)
    case media(ItemID)
}

@Observable
@MainActor
final class SMBBrowseViewModel {
    private(set) var folders: [SMBDirectoryEntry] = []
    private(set) var media: [Item] = []
    /// Bumped every time a fresh listing lands (load, re-sort). The browse view keys its prefetch
    /// watermark on this SYNCHRONOUSLY (checked inside the tile-appear handler), because an async
    /// reset (`.task(id:)`) loses to the re-materialized cells' synchronous `onAppear` and a
    /// stale-high watermark would silently suppress the new listing's prefetch window.
    private(set) var listingGeneration = 0
    /// Strict per-item sidecar-image matches for `media` (keyed by `ItemID`); only matched items
    /// appear. Threaded to each tile so the thumbnail provider prefers a real poster over a frame-grab.
    private(set) var artwork: [ItemID: SMBDirectoryEntry] = [:]
    private(set) var isLoading = false
    /// True while a background re-list is in flight over content that is already on screen
    /// (stale-while-revalidate). The view dims via `.staleWhileRevalidate` and never swaps to a
    /// skeleton — current folders/media stay put until fresh data lands or the revalidate fails
    /// silently.
    private(set) var isRefreshing = false
    private(set) var error: String?
    /// True when the last failure was the server refusing the SIGN-IN (`.auth`, e.g. libsmb2's
    /// EPERM for a stale/lost password) rather than a share/connectivity fault. The share-root
    /// failure screen keys on this: "Share Unavailable — offline or renamed" is a misdiagnosis
    /// when the actual fix is updating the stored credentials.
    private(set) var errorIsSignInRefusal = false

    // MARK: Scroll anchor (reflow restoration)

    /// Visible-tile identities per section, in layout order (topmost first), maintained by the
    /// grid's `onScrollTargetVisibilityChange`. Deliberately `@ObservationIgnored`: these mutate
    /// on every tile boundary crossing while the user scrolls, and nothing may observe that —
    /// reading them from `body` would put each crossing back on the view's invalidation path.
    /// Only the width-change restore reads them, outside body evaluation.
    @ObservationIgnored var visibleFolderIDs: [SMBDirectoryEntry] = []
    @ObservationIgnored var visibleMediaIDs: [ItemID] = []

    /// The identity to re-anchor the wall to across a width change (device rotation during an
    /// iPhone playback session): the topmost visible folder if any are on screen, else the
    /// topmost visible media tile. Folders render above media, so a non-empty folder list wins.
    /// A dedicated enum rather than `AnyHashable`: `scrollTo(id:)` requires `Sendable`, and
    /// `AnyHashable`'s own `Sendable` conformance is unavailable (a typeless box can't vouch for
    /// its payload); both wrapped values here are `Sendable`, so this conforms structurally.
    var scrollAnchorID: SMBBrowseScrollAnchor? {
        if let folder = visibleFolderIDs.first { return .folder(folder) }
        return visibleMediaIDs.first.map { .media($0) }
    }

    /// Showing the blocking full-screen failure with nothing listed (share-root or per-folder
    /// error) — the state an offline→online recovery should re-`load()`. Drives `.recoversFromOffline`.
    var isStalled: Bool { error != nil && folders.isEmpty && media.isEmpty }

    /// The level's ordering. A directory level is small and the share is already connected, so a
    /// change just re-lists this one directory (fast, and picks up any on-disk changes) instead of
    /// caching + re-sorting in memory. The previous listing stays on screen until the new one
    /// arrives (the view only shows a spinner when nothing is loaded yet).
    var sort: SMBBrowseSort = .default {
        didSet { if sort != oldValue { load() } }
    }

    // Picker lenses over the value-type `sort` (mirrors `LibraryGridViewModel`): views bind to
    // `$model.sortField` / `$model.sortDirection`, each setter writes back through `sort` so its
    // `didSet` reload fires, each getter reads the stored value so `@Observable` tracks it.
    var sortField: SMBBrowseSort.Field {
        get { sort.field }
        // Adopt the field's natural direction (names A→Z, dates newest-first) rather than carry the
        // previous order, whose label would flip meaning ("Newest" → "Z to A") under a new field.
        set { sort = SMBBrowseSort(field: newValue, direction: newValue.naturalDirection) }
    }
    var sortDirection: SMBBrowseSort.Direction {
        get { sort.direction }
        set { sort = SMBBrowseSort(field: sort.field, direction: newValue) }
    }

    private let source: SMBFileSource
    private let share: String
    private let path: String
    private var loadTask: Task<Void, Never>?
    /// Monotonic token so only the LATEST listing flight may clear its own progress flag
    /// (`isLoading` for `load`, `isRefreshing` for `refresh`). A re-sort or foreground revalidate
    /// cancels the prior task, but AMSMB2's `list` ignores cooperative cancellation, so the
    /// cancelled task still resumes and would run its `defer` — clearing a flag while the new
    /// flight is in progress. The data writes are already stale-guarded by `Task.isCancelled`;
    /// this guards the shared flags. `load` and `refresh` share one counter and one `loadTask`
    /// (single-flight): whichever starts last owns the generation. Only `load` preempts — it clears
    /// `isRefreshing` so a revalidate it cancelled can't leave that flag stuck true when its defer
    /// sees a generation mismatch and skips its own clear. `refresh` never preempts (it skips
    /// while either flag is set), so it has no flag of the other's to clear.
    private var loadGeneration = 0

    init(source: SMBFileSource, share: String, path: String) {
        self.source = source
        self.share = share
        self.path = path
    }

    func load() {
        isLoading = true
        // A foreground revalidate may still be in flight; this load owns the single flight now.
        isRefreshing = false
        error = nil
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        loadTask = Task { [source, share, path, sort] in
            defer { if generation == loadGeneration { isLoading = false } }
            do {
                let listing = try await source.browse(in: path, sort: sort)
                guard !Task.isCancelled else { return }
                folders = listing.folders
                media = listing.media
                artwork = listing.artwork
                listingGeneration += 1
            } catch {
                guard !Task.isCancelled else { return }
                let appError = SMBFileSource.mapListError(error, share: share, path: path)
                if case .auth = appError {
                    self.errorIsSignInRefusal = true
                } else {
                    self.errorIsSignInRefusal = false
                }
                self.error = appError.userMessage
            }
        }
    }

    /// Stale-while-revalidate re-list of this level. The in-flight/empty/stalled split matters
    /// because `.recoversFromOffline` ALSO fires `load()` on the same `.active` edge whenever
    /// `isStalled` (errored, nothing listed): falling through to `load()` here too would race it,
    /// and the loser's cancelled listing condemns its connection to the graveyard for nothing. So:
    /// - A listing ALREADY IN FLIGHT does NOTHING. It is about to deliver fresh data, which is all
    ///   a revalidate wants; preempting it just cancels a live listing and condemns its connection.
    ///   This is also what keeps the offline-recovery race honest: `load()` clears `error`
    ///   synchronously, so by the time this runs (after the foreground flush suspension) `isStalled`
    ///   already reads false and the stalled guard below would wave the second flight through.
    /// - Empty AND no error (a healthy empty folder) falls through to `load()` — there is nothing
    ///   to preserve, and nobody else owns re-listing this case.
    /// - Empty WITH an error (a stalled level) does NOTHING — `.recoversFromOffline` owns it.
    /// - Otherwise (content on screen) revalidates in place: keeps folders/media/artwork up the
    ///   whole time, never touches `isLoading` (nothing is loading — the first guard proved it),
    ///   and never paints an error over content the user is already browsing. A failed revalidate
    ///   is a silent no-op.
    func refresh() {
        guard !isLoading, !isRefreshing else { return }
        guard !isStalled else { return }
        if folders.isEmpty && media.isEmpty {
            load()
            return
        }
        isRefreshing = true
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        // The CLOSING mark is made from inside the task, not around the call. `refresh()` returns the
        // instant it has spawned this, so a bracket at the call site would measure the spawn (~1ms)
        // and say nothing about the work. What matters is when the listing FINISHES, so the start
        // instant is captured here at spawn and the elapsed time is reported from the task's `defer`.
        let started = ContinuousClock().now
        AppDiagnostics.lifecycle.mark("→ refresh \(share)\(DiagnosticsRedaction.path(path))")
        loadTask = Task { [source, share, path, sort] in
            defer {
                if generation == loadGeneration { isRefreshing = false }
                AppDiagnostics.lifecycle.mark(
                    "← refresh \(share)\(DiagnosticsRedaction.path(path)) in \(started.duration(to: ContinuousClock().now))")
            }
            do {
                let listing = try await source.browse(in: path, sort: sort)
                guard !Task.isCancelled else { return }
                folders = listing.folders
                media = listing.media
                artwork = listing.artwork
                listingGeneration += 1
                // A stale error must not repaint over a refresh that came back healthy — an empty
                // listing here means "Nothing Here", not the old failure.
                error = nil
                errorIsSignInRefusal = false
            } catch {
                // Failed background revalidate must not paint over content the user is browsing —
                // leave folders/media/artwork/error/errorIsSignInRefusal exactly as they were.
            }
        }
    }
}
