import Foundation
import Observation
import os
import ParallaxCore
import ParallaxJellyfin

@Observable
@MainActor
final class MovieDetailViewModel {
    enum LoadState: Equatable {
        case idle, loading, loaded(MovieDetail), failed(String)
    }

    private(set) var state: LoadState = .idle
    private(set) var isFavorite = false
    private(set) var isPlayed = false

    /// Showing the blocking full-screen failure — the state an offline→online recovery should
    /// re-`load()`. Drives `.recoversFromOffline`.
    var isStalled: Bool { if case .failed = state { true } else { false } }
    /// Drives the stale-while-revalidate dim during `refresh()` (re-pull after a
    /// playback session ends). Also a re-entrancy guard.
    private(set) var isRefreshing = false
    /// True while a played toggle is round-tripping. `togglePlayed` gates re-entrant calls on
    /// this: the service's own per-`(itemID, .played)` guard coalesces the NETWORK write, but
    /// not this VM's local optimistic flip — without gating here, a rapid double-tap would flip
    /// `isPlayed` back for a frame before the first call's `.skipped` resolution re-settles it.
    /// Also read by `refresh()` and `apply(_:)` so they don't clobber the optimistic value with a
    /// differently-sourced broadcast or re-fetch landing mid-toggle.
    private var playedInFlight = false
    private let repo: LibraryRepository
    private let itemID: ItemID
    private let userDataActions: UserDataActions
    private var changesTask: Task<Void, Never>?

    init(repo: LibraryRepository, itemID: ItemID, userDataActions: UserDataActions) {
        self.repo = repo
        self.itemID = itemID
        self.userDataActions = userDataActions
        // Own the iterating Task; cancelled in deinit.
        changesTask = userDataActions.subscribe { [weak self] change in
            self?.apply(change)
        }
    }

    isolated deinit {
        changesTask?.cancel()
    }

    /// React to a user-data change from any surface (self-notification included — the event
    /// carries the server's fresh copy, so re-applying it is idempotent). The patch goes
    /// through `change.merged(into:)`, not the raw payload: a played-operation response's
    /// favorite field (or a favorite response's played/position fields) is a DTO-boundary
    /// default, not real state, so adopting it wholesale would flip the field the OTHER
    /// operation owns. Because the merge already keeps the untouched field equal to what
    /// `detail.movie.userData` held, mirroring both `isFavorite`/`isPlayed` off the merged
    /// result is safe even for a same-operation change. `isPlayed` still skips the patch while
    /// `playedInFlight` — the same no-clobber rule `refresh()` follows — so a
    /// differently-sourced broadcast landing mid-toggle can't revert the optimistic value.
    private func apply(_ change: UserDataActions.Change) {
        guard case .loaded(let detail) = state, detail.movie.id == change.itemID else { return }
        let merged = change.merged(into: detail.movie.userData)
        state = .loaded(detail.withMovie(detail.movie.withUserData(merged)))
        isFavorite = merged.isFavorite
        if !playedInFlight { isPlayed = merged.played }
    }

    func load() async {
        state = .loading
        do {
            let detail = try await repo.detail(for: itemID)
            guard case .movie(let md) = detail else {
                state = .failed("Your server returned something that isn't a movie.")
                return
            }
            state = .loaded(md)
            isFavorite = md.movie.userData.isFavorite
            isPlayed = md.movie.userData.played
        } catch let error as AppError {
            Log.ui.error("MovieDetail load failed: \(error.userMessage)")
            state = .failed(error.userMessage)
        } catch {
            Log.ui.error("MovieDetail load unexpected: \(String(describing: type(of: error)))")
            state = .failed("Something went wrong. Go back and open it again.")
        }
    }

    /// Re-pull the movie after a playback session ends so its progress-driven UI — the
    /// Resume/Play label and the watched check — reflects the position the player just
    /// moved. Stays on `.loaded` (no skeleton flash) and lets the `staleWhileRevalidate`
    /// dim cover the swap. Re-fetch failure is non-fatal: keep the stale detail, log.
    func refresh() async {
        guard case .loaded = state, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let detail = try await repo.detail(for: itemID)
            guard case .movie(let md) = detail else { return }
            state = .loaded(md)
            // Finishing a movie marks it played server-side, so pick that up — but not
            // while a manual Mark-Watched toggle is still round-tripping (`togglePlayed`
            // owns the field until its write resolves). Favorite is never moved by
            // playback, so refresh leaves `isFavorite` alone rather than race an
            // in-flight favorite toggle.
            if !playedInFlight { isPlayed = md.movie.userData.played }
        } catch {
            Log.ui.error("MovieDetail refresh failed: \(String(describing: type(of: error)))")
        }
    }

    func toggleFavorite() async {
        let original = isFavorite
        isFavorite = !original
        switch await userDataActions.toggleFavorite(itemID: itemID, currentlyFavorite: original, via: repo) {
        case .success(let server):
            isFavorite = server.isFavorite
        case .skipped:
            isFavorite = original
        case .failure(let error):
            isFavorite = original
            Log.ui.error("toggleFavorite failed: \(error.userMessage) (\(error.networkDiagnostic))")
        }
    }

    func togglePlayed() async {
        // The service's in-flight guard coalesces the NETWORK write only — it never sees this
        // VM's local optimistic flip. Without this early-return, a rapid double-tap would flip
        // `isPlayed` back to `original` for a frame before the first call's `.skipped` outcome
        // re-settles it, a visible checkmark flicker.
        guard !playedInFlight else { return }
        let original = isPlayed
        playedInFlight = true
        defer { playedInFlight = false }
        isPlayed = !original
        switch await userDataActions.togglePlayed(itemID: itemID, currentlyPlayed: original, via: repo) {
        case .success(let server):
            isPlayed = server.played
        case .skipped:
            isPlayed = original
        case .failure(let error):
            isPlayed = original
            Log.ui.error("togglePlayed failed: \(error.userMessage) (\(error.networkDiagnostic))")
        }
    }
}

/// `MovieDetail`'s fields are `let` (no package-side mutated-copy API — adding one is a
/// `ParallaxCore` change, out of this task's scope), so patching the `movie` field alone still
/// needs a full-struct copy. Kept to this one call site rather than rolled ad hoc: every other
/// field is passed through UNCHANGED (never recomputed), so there's nothing for a future field
/// to silently drop.
private extension MovieDetail {
    func withMovie(_ movie: Movie) -> MovieDetail {
        MovieDetail(movie: movie, tagline: tagline, studios: studios, directors: directors, people: people, chapters: chapters)
    }
}
