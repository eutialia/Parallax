import Observation
import ParallaxCore
import ParallaxFileBrowse
import ParallaxJellyfin

/// Backs one level of `SMBBrowseView`: lists a single directory of a share into name-sorted
/// subfolders (drill targets) and playable media. One view model per browsed level — each
/// `SMBBrowseView` builds its own lister/`SMBFileSource` (an `AMSMB2Lister` is an actor, so it
/// can't ride the `Hashable` nav value) and tears it down on disappear.
///
/// Loading cancels any in-flight task before starting a new one; a stale-guard on the current
/// path ensures a slow, cancelled load can't overwrite the live directory. The level's path is
/// fixed for the model's lifetime, so the guard collapses to the cancellation check — but it's
/// kept explicit so the pattern remains readable. Failures map through `SMBFileSource.mapListError`
/// to the same `AppError` `userMessage` the Jellyfin grid surfaces (`LibraryGridViewModel`), so
/// SMB and Jellyfin errors read in one voice.
@Observable
@MainActor
final class SMBBrowseViewModel {
    private(set) var folders: [SMBDirectoryEntry] = []
    private(set) var media: [Item] = []
    private(set) var isLoading = false
    private(set) var error: String?

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

    /// Mirror of `LibraryGridViewModel`'s teardown deinit: if the level is released without
    /// `.onDisappear` firing (a programmatic path reset), still cancel the in-flight list and close
    /// the share socket — the load Task retains `self` + the `SMBFileSource` until `browse` returns.
    /// Identical to `teardown()`, so it just calls it (the spawned disconnect captures `source`, not
    /// `self`, so it safely outlives deinit).
    isolated deinit {
        teardown()
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
            } catch {
                guard !Task.isCancelled else { return }
                self.error = SMBFileSource.mapListError(error, share: share, path: path).userMessage
            }
        }
    }

    /// Cancel the in-flight list and drop the share connection. Called from the view's
    /// `.onDisappear` regardless of how the level leaves (back, deeper push, app background);
    /// `SMBFileSource.disconnect()` forwards to the lister actor, so it's safe from MainActor.
    func teardown() {
        loadTask?.cancel()
        Task { [source] in await source.disconnect() }
    }
}
