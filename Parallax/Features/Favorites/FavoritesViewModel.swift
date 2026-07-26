import Foundation
import Observation
import ParallaxCore
import ParallaxJellyfin

/// Favorites across every signed-in Jellyfin server, as one **section per server** rather than one
/// merged list.
///
/// Sectioning is what makes the sort control honest. Favorites carries the full library toolbar —
/// five sort fields, a direction, and a genre filter — and each server sorts its own results
/// server-side. Concatenating those streams under a single global "Title A→Z" gives a list that
/// runs A→Z, then starts over at A halfway down: each half is sorted, the whole is visibly not.
/// Interleaving them instead needs a client-side comparator that agrees with the server's ordering,
/// which two of the five fields can't support — `releaseDate` (the default) is sorted server-side on
/// full `PremiereDate` while `Movie`/`Series` keep only `year`, and `title` is sorted on `SortName`,
/// which the server lowercases, article-normalizes, and lets users override per item. Showing the
/// seam sidesteps both: each section is exactly the order its server returned, so fidelity is
/// perfect and no cross-server comparison is ever made.
///
/// It also keeps pagination free. Each section owns a `LibraryGridViewModel` — the same one a
/// single-server library grid uses, unchanged — so paging, genre fetching, stale-while-revalidate,
/// and source-scoped user-data patching all come along. This type only fans one sort/filter choice
/// out to them and unions their genres.
@Observable
@MainActor
final class FavoritesViewModel {
    /// One server's favorites. `id` is the source, so a section survives its items changing.
    ///
    /// Holds the `Session` directly rather than a `LibrarySource`: favorites are a Jellyfin concept
    /// (SMB has no favorite flag), so every section is Jellyfin-backed by construction, and the
    /// tiles need the session anyway to build artwork URLs against their OWN server.
    struct Section: Identifiable {
        let session: Session
        let grid: LibraryGridViewModel
        var id: ServerID { session.id }
        var title: String { session.serverName }
    }

    private(set) var sections: [Section] = []

    /// The one sort every section is held to. Writing it fans out; each grid reloads itself from
    /// its own server, which is what keeps each section's order server-authoritative.
    var sort: ItemSort = .defaultForLibrary {
        didSet {
            guard sort != oldValue else { return }
            for section in sections { section.grid.sort = sort }
        }
    }

    var filter: ItemFilter = ItemFilter() {
        didSet {
            guard filter != oldValue else { return }
            for section in sections { section.grid.filter = filter }
        }
    }

    // Picker lenses matching `LibraryGridViewModel`'s, so the shared controls drive this coordinator
    // exactly as they drive a single grid.
    var selectedGenre: String? {
        get { filter.genres.first }
        set { filter.genres = newValue.map { [$0] } ?? [] }
    }

    var sortField: ItemSort.Field {
        get { sort.field }
        // Picking a field adopts its natural direction (dates newest-first, titles A→Z) instead of
        // inheriting the previous field's order — the direction palette re-labels per field, so a
        // carried-over direction would silently flip meaning ("Newest" → "Z to A").
        set { sort = ItemSort(field: newValue, direction: newValue.naturalDirection) }
    }

    var sortDirection: ItemSort.Direction {
        get { sort.direction }
        set { sort = ItemSort(field: sort.field, direction: newValue) }
    }

    /// Every genre offered by any server, deduplicated and sorted — a genre that exists on only one
    /// server still has to be selectable, or its titles are unreachable. Selecting one legitimately
    /// empties the sections that don't carry it; the section headers are what make that read as
    /// "nothing here" rather than as a bug.
    var availableGenres: [String] {
        Array(Set(sections.flatMap(\.grid.availableGenres))).sorted()
    }

    /// True only while EVERY section is still fetching its genres — the first-load skeleton
    /// condition. One slow server shouldn't hold the controls in a skeleton once another has
    /// answered.
    var isLoadingGenres: Bool {
        !sections.isEmpty && sections.allSatisfy(\.grid.isLoadingGenres)
    }

    /// Sections with something to draw. An empty section renders as a bare header over nothing,
    /// which reads as breakage; a server with no favorites simply isn't mentioned. A section that
    /// FAILED is kept (see `failedSections`) so the user learns which server is unreachable rather
    /// than silently seeing fewer favorites than they have.
    var visibleSections: [Section] {
        sections.filter { !$0.grid.items.isEmpty || $0.grid.isStalled }
    }

    /// Sections whose fetch failed outright. Rendered with an inline message under their header.
    var failedSections: [Section] {
        sections.filter(\.grid.isStalled)
    }

    /// Every section has settled and none has anything — the real "No Favorites" state, as opposed
    /// to the transient one during loading.
    var isEmpty: Bool {
        !sections.isEmpty && sections.allSatisfy { $0.grid.items.isEmpty && $0.grid.state == .loaded }
    }

    /// Nothing has landed anywhere yet.
    var isInitialLoad: Bool {
        sections.isEmpty || sections.allSatisfy { $0.grid.items.isEmpty && $0.grid.state != .loaded && !$0.grid.isStalled }
    }

    /// Every server failed. Only then does the whole screen become an error — one unreachable
    /// server out of two must not hide the other's favorites.
    var hasFailedEntirely: Bool {
        !sections.isEmpty && sections.allSatisfy(\.grid.isStalled)
    }

    /// Build one section per signed-in server, in the store's order (Jellyfin add order), and load
    /// them concurrently. Sections are created before loading so the wall can render its headers and
    /// per-section skeletons while the fetches are in flight.
    func load(
        sessions: [Session],
        repoFactory: @Sendable (Session) async -> any MediaRepository,
        userDataActions: UserDataActions
    ) async {
        var built: [Section] = []
        for session in sessions {
            // The current sort/filter go in through `init`, not assigned afterwards: assigning
            // fires the grid's `didSet` reload, which races the `load()` below and can make it
            // bail (`guard state != .loading`) — taking `loadGenres()` with it, so a wall rebuilt
            // while a sort was active came back with no genres to pick from.
            let grid = LibraryGridViewModel(
                repo: await repoFactory(session),
                source: .jellyfin(session.id),
                scope: .favorites,
                userDataActions: userDataActions,
                sort: sort,
                filter: filter
            )
            built.append(Section(session: session, grid: grid))
        }
        sections = built

        // Concurrent, and each section commits its own state as it lands: a slow server delays only
        // its own strip. `LibraryGridViewModel` is `@MainActor`, so these interleave at await points
        // rather than running in parallel — the win is the overlapped network time, not CPU.
        await withTaskGroup(of: Void.self) { group in
            for section in built {
                group.addTask { @MainActor in await section.grid.load() }
            }
        }
    }

    /// Re-run the failed sections only. Drives `.recoversFromOffline`, so a reconnect repairs the
    /// unreachable server without re-pulling the ones already on screen.
    func reloadFailedSections() async {
        await withTaskGroup(of: Void.self) { group in
            for section in sections where section.grid.isStalled {
                group.addTask { @MainActor in await section.grid.load() }
            }
        }
    }
}
