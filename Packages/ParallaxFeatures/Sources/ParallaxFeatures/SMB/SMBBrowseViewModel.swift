import Foundation
import Observation
import ParallaxCore
import ParallaxFileBrowse
import ParallaxJellyfin

/// Navigation value for one level of an SMB share browse. Drilling into a folder just pushes a new
/// value with the child's path. The lister/`SMBFileSource` is deliberately NOT carried here —
/// neither is `Hashable` — so each level's `SMBBrowseViewModel` builds its own from `ref` in
/// `open()`. Rebuilding is cheap: the lister only borrows from the shared connection pool.
public struct SMBBrowsePath: Hashable {
    /// The owning server — supplies the host + credentials to build a lister for this level.
    public let ref: SMBServerRef
    /// The share being browsed (the server can host many).
    public let share: String
    /// Share-relative path of this level; empty = share root.
    public let path: String

    public init(ref: SMBServerRef, share: String, path: String) {
        self.ref = ref
        self.share = share
        self.path = path
    }
}

/// Backs one level of `SMBBrowseView`: builds the level's lister (`open()`), lists a single
/// directory of a share into sorted subfolders (drill targets) and playable media, warms the
/// thumbnails a viewport ahead, and plays a tapped file. One view model per browsed level — each
/// builds its own lister/`SMBFileSource` (a lister can't ride the `Hashable` nav value). The lister
/// is a thin, stateless borrower of the shared connection pool, so a level owns no connection and
/// has nothing to tear down.
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
/// **Leaving a level DOES withdraw its thumbnails.** Prefetch covers only the level on screen:
/// `appear()` holds the level's thumbnail work for as long as the view's `.task` runs, and SwiftUI
/// cancelling that task on a push or pop withdraws whatever is still queued.
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
public final class SMBBrowseViewModel {
    /// Whether the level's lister exists yet. Building it reads the Keychain, so it can fail before
    /// anything is listed.
    public enum Setup: Equatable {
        case opening
        case open
        /// `isCredentialLoss`: the saved password's Keychain slot is gone. Terminal — no automatic
        /// retry helps, the user has to supply the password — and the one setup failure that offers
        /// password recovery. Anything else (a transient Keychain read error) stays recoverable.
        case failed(message: String, isCredentialLoss: Bool)
    }

    public let path: SMBBrowsePath
    public private(set) var setup = Setup.opening
    public private(set) var folders: [SMBDirectoryEntry] = []
    public private(set) var media: [Item] = []
    /// Strict per-item sidecar-image matches for `media` (keyed by `ItemID`); only matched items
    /// appear. Threaded to each tile so the thumbnail provider prefers a real poster over a frame-grab.
    public private(set) var artwork: [ItemID: SMBDirectoryEntry] = [:]
    public private(set) var isLoading = false
    /// True while a background re-list is in flight over content that is already on screen
    /// (stale-while-revalidate). The view dims via `.staleWhileRevalidate` and never swaps to a
    /// skeleton — current folders/media stay put until fresh data lands or the revalidate fails
    /// silently.
    public private(set) var isRefreshing = false
    public private(set) var error: String?
    /// True when the last failure was the server refusing the SIGN-IN (`.auth`, e.g. libsmb2's
    /// EPERM for a stale/lost password) rather than a share/connectivity fault. The share-root
    /// failure screen keys on this: "Share Unavailable — offline or renamed" is a misdiagnosis
    /// when the actual fix is updating the stored credentials.
    public private(set) var errorIsSignInRefusal = false

    /// Whether this level is the one the user is looking at. A level covered by a pushed screen
    /// stays mounted and must not re-list under it, so the view reports its appearance here.
    public var isOnScreen = false

    /// Showing a blocking failure with nothing listed — a recoverable setup failure, or a
    /// share-root/per-folder listing error — the state an offline→online `recover()` repairs.
    /// Offline recovery acts on it.
    public var isStalled: Bool {
        switch setup {
        case .opening: false
        case .failed(_, let isCredentialLoss): !isCredentialLoss
        case .open: error != nil && folders.isEmpty && media.isEmpty
        }
    }

    /// The level's ordering. A directory level is small and the share is already connected, so a
    /// change just re-lists this one directory (fast, and picks up any on-disk changes) instead of
    /// caching + re-sorting in memory. The previous listing stays on screen until the new one
    /// arrives (the view only shows a spinner when nothing is loaded yet).
    public var sort: SMBBrowseSort = .default {
        didSet { if sort != oldValue { load() } }
    }

    // Picker lenses over the value-type `sort` (mirrors `LibraryGridViewModel`): views bind to
    // `$model.sortField` / `$model.sortDirection`, each setter writes back through `sort` so its
    // `didSet` reload fires, each getter reads the stored value so `@Observable` tracks it.
    public var sortField: SMBBrowseSort.Field {
        get { sort.field }
        // Adopt the field's natural direction (names A→Z, dates newest-first) rather than carry the
        // previous order, whose label would flip meaning ("Newest" → "Z to A") under a new field.
        set { sort = SMBBrowseSort(field: newValue, direction: newValue.naturalDirection) }
    }
    public var sortDirection: SMBBrowseSort.Direction {
        get { sort.direction }
        set { sort = SMBBrowseSort(field: sort.field, direction: newValue) }
    }

    private let makeLister: (SMBServerRef) async throws -> any SMBLister
    private let artworkProvider: MediaArtworkProvider
    private let playback: PlaybackPresenter
    private var source: SMBFileSource?
    private var loadTask: Task<Void, Never>?
    /// The level's one open, kept after it settles so later calls do nothing. `openGeneration`
    /// lets a replaced open tell it is no longer the current one.
    private var openTask: Task<Void, Never>?
    private var openGeneration = 0
    /// Highest media index the viewport-ahead prefetch window has covered; -1 = none yet. Monotonic
    /// per listing so scroll-back re-appearances don't re-hand items to the provider, and reset in
    /// the same main-actor turn a fresh listing lands, so no re-materialized cell's onAppear can
    /// read the dead order's watermark.
    private var prefetchedThrough = -1
    /// Where `prefetchWindow` sends a window. With no appearance holding the level, windows wait in
    /// a buffer, so one asked for before `appear` takes over (a tile materialising on the pop back,
    /// ahead of the view's `.task`) still lands. Each appearance owns its own stream, tagged with its
    /// epoch, so one still winding down after a newer one started never touches the newer one's state.
    private var prefetchSink = PrefetchSink.buffering([])
    private var appearances = 0
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

    init(
        path: SMBBrowsePath,
        makeLister: @escaping (SMBServerRef) async throws -> any SMBLister,
        artworkProvider: MediaArtworkProvider,
        playback: PlaybackPresenter
    ) {
        self.path = path
        self.makeLister = makeLister
        self.artworkProvider = artworkProvider
        self.playback = playback
    }

    /// What the view's `.task` runs each time the level appears: marks it as the one on screen, opens
    /// it if it isn't open yet, then runs its thumbnail prefetch until the task is cancelled — the
    /// level leaving the screen, pushed past or popped. The cancellation withdraws every thumbnail
    /// the level still waits on. An open that was cancelled before it built the lister left the
    /// level `.opening`, so the next appearance picks it up again.
    public func appear() async {
        isOnScreen = true
        await open()
        guard !Task.isCancelled else { return }
        appearances += 1
        let epoch = appearances
        let (windows, sink) = AsyncStream<PrefetchWindow>.makeStream()
        switch prefetchSink {
        case .buffering(let buffered):
            buffered.forEach { sink.yield($0) }
        case .appearance:
            // The previous appearance is still winding down and withdraws what it was handed.
            prefetchedThrough = -1
        }
        prefetchSink = .appearance(epoch, sink)
        let (artworkProvider, ref) = (artworkProvider, path.ref)
        await withDiscardingTaskGroup { group in
            for await window in windows {
                group.addTask { await artworkProvider.prefetch(window.items, ref: ref, sidecars: window.sidecars) }
            }
        }
        guard case .appearance(epoch, _) = prefetchSink else { return }
        prefetchSink = .buffering([])
        prefetchedThrough = -1
    }

    /// Builds this level's lister and starts the first list. Failure before the lister exists lands
    /// in `setup`; only a confirmed-lost credential slot is terminal. There is one open at a time:
    /// callers join the one in flight, and once it has settled this does nothing. A cancelled open
    /// changes nothing and is forgotten, so the level stays reopenable; cancelling the caller
    /// cancels the open.
    public func open() async {
        let task = openTask ?? startOpen()
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func startOpen() -> Task<Void, Never> {
        openGeneration += 1
        let generation = openGeneration
        let task = Task { await self.buildSource(generation: generation) }
        openTask = task
        return task
    }

    private func buildSource(generation: Int) async {
        func abandon() {
            if openGeneration == generation { openTask = nil }
        }
        do {
            let lister = try await makeLister(path.ref)
            // The factory awaits a Keychain read, so this level may already have been popped, or
            // the open replaced after a password change, by the time it returns.
            guard !Task.isCancelled else { return abandon() }
            source = SMBFileSource(lister: lister, host: path.ref.data.host, share: path.share, root: "")
            setup = .open
            load()
        } catch {
            guard !Task.isCancelled else { return abandon() }
            let appError = error as? AppError
            let isCredentialLoss = if case .auth(.credentialUnavailable) = appError { true } else { false }
            setup = .failed(
                message: appError?.userMessage ?? "Couldn't open this share.",
                isCredentialLoss: isCredentialLoss
            )
        }
    }

    /// The offline→online repair for a stalled level: re-list it, or rebuild it when the lister
    /// never got built. An open still in flight is joined, not restarted.
    public func recover() async {
        guard source != nil else {
            if case .failed = setup {
                setup = .opening
                openTask = nil
            }
            await open()
            return
        }
        load()
    }

    /// After a new password verified and was stored: rebuild the lister. Deliberately NOT `load()`
    /// — the current lister was built with the OLD password (it's baked into the credentials the
    /// pool keys connections by), so re-listing through it would just be refused again. An open
    /// still in flight holds the old password, so it is cancelled and replaced.
    public func reopenAfterPasswordRecovery() async {
        openTask?.cancel()
        openTask = nil
        loadTask?.cancel()
        source = nil
        folders = []
        media = []
        artwork = [:]
        error = nil
        errorIsSignInRefusal = false
        setup = .opening
        await open()
    }

    /// Plays a browsed file through the app's one player.
    public func play(_ item: Item) {
        playback.playSMB(item, ref: path.ref)
    }

    /// Viewport-ahead prefetch: when the media tile at `index` materialises, hands the level's
    /// prefetch the tile's own item and the next `lookahead` items, all those past the current
    /// watermark. Monotonic, so each item is handed over once per listing and appearance; the
    /// provider dedupes any overlap (cache / pending / negative-cache) anyway. A tile below the
    /// watermark was already claimed by the level, so scrolling it off withdraws only its visible
    /// priority: its thumbnail still finishes while the level is on screen, unless the bounded
    /// prefetch backlog evicts it first.
    public func prefetchWindow(from index: Int, lookahead: Int) {
        let upper = min(index + lookahead, media.count - 1)
        let lower = max(prefetchedThrough + 1, index)
        guard lower <= upper else { return }
        prefetchedThrough = upper
        let window = PrefetchWindow(items: Array(media[lower...upper]), sidecars: artwork)
        switch prefetchSink {
        case .buffering(let buffered):
            prefetchSink = .buffering(buffered + [window])
        case .appearance(_, let sink):
            // The appearance was cancelled but has not wound down yet: the window belongs to the next.
            guard case .terminated = sink.yield(window) else { return }
            prefetchSink = .buffering([])
            prefetchedThrough = -1
            prefetchWindow(from: index, lookahead: lookahead)
        }
    }

    public func load() {
        guard let source else { return }
        isLoading = true
        // A foreground revalidate may still be in flight; this load owns the single flight now.
        isRefreshing = false
        error = nil
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        loadTask = Task { [source, share = path.share, path = path.path, sort] in
            defer { if generation == loadGeneration { isLoading = false } }
            do {
                let listing = try await source.browse(in: path, sort: sort)
                guard !Task.isCancelled else { return }
                show(listing)
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
    /// because offline recovery ALSO fires `load()` on the same `.active` edge whenever
    /// `isStalled` (errored, nothing listed): falling through to `load()` here too would race it,
    /// and the loser's cancelled listing condemns its connection to the graveyard for nothing. So:
    /// - A listing ALREADY IN FLIGHT does NOTHING. It is about to deliver fresh data, which is all
    ///   a revalidate wants; preempting it just cancels a live listing and condemns its connection.
    ///   This is also what keeps the offline-recovery race honest: `load()` clears `error`
    ///   synchronously, so by the time this runs (after the foreground flush suspension) `isStalled`
    ///   already reads false and the stalled guard below would wave the second flight through.
    /// - Empty AND no error (a healthy empty folder) falls through to `load()` — there is nothing
    ///   to preserve, and nobody else owns re-listing this case.
    /// - Empty WITH an error (a stalled level) does NOTHING — offline recovery owns it.
    /// - Otherwise (content on screen) revalidates in place: keeps folders/media/artwork up the
    ///   whole time, never touches `isLoading` (nothing is loading — the first guard proved it),
    ///   and never paints an error over content the user is already browsing. A failed revalidate
    ///   is a silent no-op.
    public func refresh() {
        guard let source, !isLoading, !isRefreshing else { return }
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
        let lifecycle = Log.retained(category: "AppLifecycle")
        let (share, path) = (path.share, path.path)
        lifecycle.mark("→ refresh \(share)\(DiagnosticsRedaction.path(path))")
        loadTask = Task { [source, sort] in
            defer {
                if generation == loadGeneration { isRefreshing = false }
                lifecycle.mark(
                    "← refresh \(share)\(DiagnosticsRedaction.path(path)) in \(started.duration(to: ContinuousClock().now))")
            }
            do {
                let listing = try await source.browse(in: path, sort: sort)
                guard !Task.isCancelled else { return }
                show(listing)
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

    private func show(_ listing: SMBBrowseListing) {
        folders = listing.folders
        media = listing.media
        artwork = listing.artwork
        prefetchedThrough = -1
    }
}

/// Items a level hands its thumbnail prefetch, with the sidecar matches from the same listing.
private struct PrefetchWindow: Sendable {
    let items: [Item]
    let sidecars: [ItemID: SMBDirectoryEntry]
}

/// A buffer while no appearance holds the level, or the stream of the appearance that does.
private enum PrefetchSink {
    case buffering([PrefetchWindow])
    case appearance(Int, AsyncStream<PrefetchWindow>.Continuation)
}
