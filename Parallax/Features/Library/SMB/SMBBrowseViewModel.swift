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
    private(set) var error: String?
    /// True when the last failure was the server refusing the SIGN-IN (`.auth`, e.g. libsmb2's
    /// EPERM for a stale/lost password) rather than a share/connectivity fault. The share-root
    /// failure screen keys on this: "Share Unavailable — offline or renamed" is a misdiagnosis
    /// when the actual fix is updating the stored credentials.
    private(set) var errorIsSignInRefusal = false

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
    /// Monotonic token so only the LATEST load may mutate `isLoading`. A re-sort cancels the prior
    /// task, but AMSMB2's `list` ignores cooperative cancellation, so the cancelled task still
    /// resumes and would run its `defer` — clearing `isLoading` while the new load is in flight.
    /// The data writes are already stale-guarded by `Task.isCancelled`; this guards the shared flag.
    private var loadGeneration = 0

    init(source: SMBFileSource, share: String, path: String) {
        self.source = source
        self.share = share
        self.path = path
    }

    func load() {
        isLoading = true
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
}
