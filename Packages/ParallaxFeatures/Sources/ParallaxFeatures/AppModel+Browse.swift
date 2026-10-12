import Foundation
import Observation
import ParallaxCore
import ParallaxJellyfin

/// The library list every navigation root shows: one group per configured source, plus what the
/// roots need to tell an offline server from an empty one.
public nonisolated struct LibraryList: Equatable {
    public internal(set) var groups: [LibraryGroup] = []
    /// Sources whose listing failed the last pass — the list is missing THOSE servers' libraries
    /// because the network is down, not because they have none. Gates offline recovery, and tells
    /// "every server is unreachable" apart from "no server has a visible library".
    public internal(set) var failedSourceIDs: Set<MediaSourceID> = []
    /// Names of the servers in `failedSourceIDs`, for the partial-failure notice.
    public internal(set) var failedSourceNames: [String] = []
    /// Whether any Jellyfin server is signed in — gates the cross-server Favorites entry (favorites
    /// are a Jellyfin concept).
    public internal(set) var hasJellyfinSource = false
    /// True until a pass has committed something to show.
    public internal(set) var isResolving = true
}

extension AppModel {
    /// Loads what the signed-in tabs show — the library list and Home's feed — side by side. Both
    /// navigation roots call it whenever the router's reload token moves: a server switch, a
    /// source added or removed, a Visible Libraries edit.
    ///
    /// The launch hold releases once what `launchReveal` covers has settled. Cached content
    /// releases it sooner (see `loadLibraries()` / `loadHome()`).
    public func loadSources() async {
        async let librariesLoaded: Void = loadLibraries()
        await loadHome()
        if launchReveal == .home { releaseLaunchHold() }
        await librariesLoaded
        releaseLaunchHold()
    }

    /// Loaded OR failed, both are revealable. A cancelled pass leaves the release to the pass that
    /// superseded it; bootstrapping has nothing to reveal yet; and a desync re-route to login
    /// finishes the stage itself. One-shot; later passes are no-ops inside the gate.
    private func releaseLaunchHold() {
        guard !Task.isCancelled, router.destination == .home else { return }
        launchGate.markContentReady()
    }

    /// Resolves every source's libraries in ONE `MergedLibrary` pass. Also the offline-recovery
    /// path, so the launch and reconnect loads never drift. Commits under a cancellation check: a
    /// token change cancels the pass and starts a fresh one, and a now-stale snapshot must not
    /// clobber the newer state.
    public func loadLibraries() async {
        // Clear, don't just return: dropping the last source must not leave a stale list rendered.
        guard router.hasAnySource else {
            libraries = LibraryList(isResolving: false)
            return
        }
        // One read of the store's shape drives both stages (see `MergedLibrary.SourceState`) — and
        // the Favorites gate reads the same `sessions`, so the two can't disagree.
        let sources = await MergedLibrary.SourceState.read(from: services.serverStore)
        // Stale-while-revalidate: the last known listing goes up before the network pass.
        if let cached = await sources.hydratedGroups(ifColdGiven: libraries.groups, snapshots: services.snapshots) {
            libraries.groups = cached
            libraries.hasJellyfinSource = !sources.sessions.isEmpty
            libraries.isResolving = false
            if launchReveal == .homeAndLibraries { launchGate.markContentReady() }
        }
        let outcome = await sources.resolve(
            retaining: libraries.groups,
            snapshots: services.snapshots,
            jellyfinRepo: services.mediaRepoFactory
        )
        guard !Task.isCancelled else { return }
        libraries = LibraryList(
            groups: outcome.groups,
            failedSourceIDs: outcome.failedSourceIDs,
            failedSourceNames: outcome.failedSourceNames,
            hasJellyfinSource: !sources.sessions.isEmpty,
            isResolving: false
        )
    }

    /// Builds and loads Home's feed. Re-runs on every reload-token move; each step is guarded so an
    /// already-built model isn't rebuilt.
    func loadHome() async {
        // No Jellyfin session to feed Home: transient during bootstrapping (the source set lands
        // shortly and the token moves, re-running this), and for good in an SMB-only setup, where
        // Home is the placeholder.
        guard router.activeServerID != nil else {
            home = nil
            return
        }
        let feeds = await HomeViewModel.Feed.all(
            for: await services.serverStore.sessions,
            repoFactory: services.jellyfinLibraryRepoFactory
        )
        // The router cached an active server the store can no longer produce a session for — a
        // desync (session cleared elsewhere, or a failed credential/keychain rebuild). Sessions are
        // never transiently empty here (stable actor state, `load()` is already done), so an empty
        // list means the cached id is genuinely stale. Re-sync the router to the store's truth
        // instead of releasing the launch reveal onto an endless skeleton: with no Jellyfin session
        // it falls to SMB-only home if an SMB source remains, else to `.login` (which finishes the
        // launch stage), where the user can re-authenticate.
        guard !feeds.isEmpty else {
            home = nil
            await routeToSources()
            return
        }
        // Rebuild when the SET of servers changed, not just when there's no model yet. A model's
        // feeds are fixed at init, so signing into a second server must not leave the single-server
        // model in place. Comparing source ids rather than rebuilding unconditionally keeps the
        // loaded shelves on screen when the token moved for an unrelated reason (a visible-libraries
        // edit, an SMB share re-selection, an active-server switch), which would otherwise flash the
        // skeleton for no new content.
        if home?.sourceIDs != feeds.map(\.source.sourceID) {
            let model = HomeViewModel(feeds: feeds, userDataActions: userDataActions, snapshots: services.snapshots)
            home = model
            // Stale-while-revalidate: the last feed these servers returned is on disk, so put it up
            // as loaded content and release the launch hold on it — the reveal then opens onto real
            // content instead of a skeleton, and `load()` below replaces it in place.
            if await model.hydrateFromCache() { launchGate.markContentReady() }
            await model.load()
        } else if home?.needsNetworkLoad == true {
            // Same servers, but the model never settled — hydrated from the cache and not yet
            // revalidated, or its previous `load()` was cancelled by this very pass re-running.
            await home?.load()
        }
    }

    /// A finished playback session moved progress, so re-pull Home's progress-driven shelves the
    /// moment the player closes. Home stays mounted under the player, so closing it is the only
    /// "back from watching" edge.
    func refreshHomeAfterPlayback() async {
        var seen: Int?
        for await closed in Observations({ self.playback.closedSessions }) {
            if let seen, closed != seen { await home?.refresh() }
            seen = closed
        }
    }

    /// Landing on login drops what Home and the library list held: the tabs are torn down, and the
    /// next sign-in must start from a clean slate rather than a previous server's shelves.
    func forgetSourcesAtLogin() async {
        for await destination in Observations({ self.router.destination }) where destination == .login {
            home = nil
            libraries = LibraryList()
        }
    }

    /// One server collection's poster grid, unloaded.
    public func libraryGrid(for collection: MediaCollection, on session: Session) async -> LibraryGridViewModel {
        let grid = LibraryGridViewModel(
            repo: await services.mediaRepoFactory(session),
            source: .jellyfin(session.id),
            scope: .collection(collection.id),
            userDataActions: userDataActions
        )
        recoverableScreens.track(grid, isStalled: { $0.isStalled }, recover: { await $0.load() })
        return grid
    }

    /// A movie's detail page, unloaded.
    public func movieDetail(_ itemID: ItemID, on session: Session) async -> MovieDetailViewModel {
        let detail = MovieDetailViewModel(
            repo: await services.jellyfinLibraryRepoFactory(session),
            itemID: itemID,
            session: session,
            userDataActions: userDataActions,
            playback: playback
        )
        recoverableScreens.track(detail, isStalled: { $0.isStalled }, recover: { await $0.load() })
        return detail
    }

    /// A series' detail page, unloaded.
    public func seriesDetail(_ itemID: ItemID, on session: Session) async -> SeriesDetailViewModel {
        let detail = SeriesDetailViewModel(
            repo: await services.jellyfinLibraryRepoFactory(session),
            itemID: itemID,
            session: session,
            userDataActions: userDataActions,
            playback: playback
        )
        recoverableScreens.track(detail, isStalled: { $0.isStalled }, recover: { await $0.load() })
        return detail
    }

    /// Runs a tile-menu entry that acts on the item: plays it, or writes its favorite or played
    /// flag. The navigation entries are the view's to push. No optimistic state here: the
    /// `UserDataActions` broadcast repaints every visible surface on success, and a failure is only
    /// logged, matching the detail pages.
    public func perform(_ action: MediaTileMenuAction, on session: Session) async {
        let source: MediaSourceID = .jellyfin(session.id)
        let outcome: UserDataActions.Outcome
        switch action {
        case .goToSeries, .viewDetails:
            return
        case .play(let itemID, _):
            playback.play(itemID, in: session)
            return
        case .playFromBeginning(let itemID):
            playback.play(itemID, in: session, fromBeginning: true)
            return
        case .toggleFavorite(let itemID, let isFavorite):
            outcome = await userDataActions.toggleFavorite(
                itemID: itemID,
                source: source,
                currentlyFavorite: isFavorite,
                via: await services.jellyfinLibraryRepoFactory(session)
            )
        case .togglePlayed(let itemID, let played), .toggleSeriesPlayed(let itemID, let played):
            outcome = await userDataActions.togglePlayed(
                itemID: itemID,
                source: source,
                currentlyPlayed: played,
                via: await services.jellyfinLibraryRepoFactory(session)
            )
        }
        if case .failure(let error) = outcome {
            Log.ui.error("menu user-data toggle failed: \(error.userMessage) (\(error.networkDiagnostic))")
        }
    }
}
