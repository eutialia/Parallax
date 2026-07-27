import ParallaxCore
import ParallaxJellyfin

/// Builds the grouped library list shown by both navigation roots (iPad sidebar + tvOS focus
/// root) and the iPhone card list. Source-symmetric and view-free so it's unit-testable: the
/// roots feed it every configured server plus the live Jellyfin sessions, and it returns one
/// `LibraryGroup` per source — each group holding that source's source-tagged `LibraryEntry`s.
///
/// Libraries are NOT merged across servers. Two servers that both expose a library called
/// "Movies" produce two entries in two groups; the app never unions them into one logical
/// library. (Home and Search DO aggregate across servers — that's their job, not this one's.)
enum MergedLibrary {
    /// The resolved groups plus a recovery signal for the nav roots.
    struct Outcome {
        /// One group per source that contributed at least one library: **Jellyfin servers first,
        /// then SMB**, and within each kind the order the user added them (see
        /// `LibrarySource.sectionRank` for why kind outranks raw add order).
        var groups: [LibraryGroup]
        /// Sources whose library listing FAILED this pass — a Jellyfin `collections()` that threw
        /// (offline / server down), never a server that legitimately has no visible libraries.
        /// The roots gate offline auto-recovery on this and re-pull only these sources, so one
        /// dead server can't put the healthy ones into a retry loop (nor stay gone once it's back).
        /// A successful-but-empty fetch and an SMB source are never in here — neither is a stall.
        var failedSourceIDs: Set<MediaSourceID>
        /// Display names of the sources in `failedSourceIDs`, in `servers` order. Carried alongside
        /// the ids because the failed sources contribute no group, so there is nothing left in
        /// `groups` to read a name from — and a partial failure that can't NAME the missing server
        /// just reads as "I have fewer libraries than I remember".
        var failedSourceNames: [String] = []

        /// Every entry across every group, flattened in group order — for stale-tab snapping.
        var entries: [LibraryEntry] { groups.allEntries }
        /// Whether ANY source failed to list. Replaces the old single `jellyfinCollectionsFailed`
        /// Bool: with N servers "stalled" is per-source, and a single flag either re-pulled all of
        /// them forever or never re-pulled the dead one.
        var hasFailures: Bool { !failedSourceIDs.isEmpty }
    }

    /// One consistent read of the store's shape (sessions + persisted servers + hidden libraries),
    /// shared by the cached and the live pass — separate reads are separate actor hops that can
    /// disagree with each other. Every root builds one of these per pass and runs both stages off
    /// it, so the hydration inputs and the resolve inputs are the same by construction, on every
    /// platform.
    struct SourceState {
        let sessions: [Session]
        let servers: [PersistedServer]
        let hiddenCollectionIDs: [ServerID: Set<String>]

        static func read(from store: ServerStore) async -> SourceState {
            SourceState(
                sessions: await store.sessions,
                servers: await store.servers,
                hiddenCollectionIDs: await store.allHiddenCollectionIDs
            )
        }

        /// `MergedLibrary.cached` over this read.
        func cachedGroups(snapshots: SnapshotStore) async -> [LibraryGroup] {
            await MergedLibrary.cached(
                sessions: sessions,
                servers: servers,
                hiddenCollectionIDs: hiddenCollectionIDs,
                snapshots: snapshots
            )
        }

        /// The stale-while-revalidate cold-start rule, single-sourced for the roots: hydrate only
        /// when nothing is on screen (a recovery pass already has live groups that disk must not
        /// overwrite), and only surface a non-empty, uncancelled result. Returns nil when the
        /// caller should leave its groups untouched.
        func hydratedGroups(ifColdGiven current: [LibraryGroup], snapshots: SnapshotStore) async -> [LibraryGroup]? {
            guard current.isEmpty else { return nil }
            let cached = await cachedGroups(snapshots: snapshots)
            guard !cached.isEmpty, !Task.isCancelled else { return nil }
            return cached
        }

        /// `MergedLibrary.resolve` over this read.
        func resolve(
            retaining previous: [LibraryGroup],
            snapshots: SnapshotStore?,
            jellyfinRepo: @escaping @Sendable (Session) async -> any MediaRepository
        ) async -> Outcome {
            await MergedLibrary.resolve(
                sessions: sessions,
                servers: servers,
                hiddenCollectionIDs: hiddenCollectionIDs,
                retaining: previous,
                snapshots: snapshots,
                jellyfinRepo: jellyfinRepo
            )
        }
    }

    /// The grouped library entries: one group per configured server, ordered **Jellyfin sections
    /// first, then SMB**, and within each kind by the order the user added them (`servers` is the
    /// persisted array — `ServerStore` appends on add and rebuilds sessions by iterating it, so
    /// that order is stable across relaunch). `LibrarySource.sectionRank` carries the reasoning for
    /// ranking by kind rather than letting raw add order decide.
    ///
    /// The two source kinds populate very differently, which is why they behave differently offline:
    /// - Jellyfin: a LIVE request (`collections()` → `GET /Users/{id}/Views`). The collection list
    ///   is server-owned state the app never persists, so enumerating it needs the network — this is
    ///   the half that fails offline (that server's libraries disappear).
    /// - SMB: network-free — the shares are the user's saved selection (persisted in `SMBServerData`),
    ///   so each maps straight to a `LibraryEntry` with no listing. They always resolve, online or
    ///   not; the network hit is deferred to opening a share.
    ///
    /// Jellyfin listings run CONCURRENTLY across servers — serially, N servers would cost N
    /// round trips before the sidebar could draw anything. A server whose `collections()` throws
    /// contributes no group and does not abort the others (a flaky server can't blank the rest of
    /// the sidebar), but its id lands in `failedSourceIDs` so the roots can re-resolve it on
    /// reconnect. A Jellyfin server with no live session (its Keychain token was lost — see
    /// `ServerStore.signedOutJellyfinServers`) is skipped silently here; Settings is where that
    /// state is surfaced.
    ///
    /// - Parameter hiddenCollectionIDs: per-server hidden library ids, keyed by `ServerID` —
    ///   the "Visible Libraries" de-selections. Applied per server, so hiding "Movies" on one
    ///   server never touches another server's same-named library.
    /// - Parameter retaining: the groups currently on screen. A server whose listing fails keeps
    ///   its group from here instead of disappearing — the sidebar must not lose libraries the
    ///   user is looking at just because a revalidation couldn't reach the server. Its id still
    ///   lands in `failedSourceIDs`, so recovery re-pulls it.
    /// - Parameter snapshots: where a successful listing is cached for the next launch. Nil skips
    ///   caching entirely (tests, and any caller that doesn't want to write).
    static func resolve(
        sessions: [Session],
        servers: [PersistedServer],
        hiddenCollectionIDs: [ServerID: Set<String>] = [:],
        retaining previous: [LibraryGroup] = [],
        snapshots: SnapshotStore? = nil,
        jellyfinRepo: @escaping @Sendable (Session) async -> any MediaRepository
    ) async -> Outcome {
        // Resolve every source concurrently, tagged with its index, then reassemble in `servers`
        // order — concurrency must not be allowed to reorder the user's servers.
        let resolved: [(index: Int, group: LibraryGroup?, failed: MediaSourceID?)] =
            await withTaskGroup(of: (Int, LibraryGroup?, MediaSourceID?).self) { taskGroup in
                for (index, server) in servers.enumerated() {
                    switch server.kind {
                    case .jellyfin:
                        // Skip a persisted Jellyfin row with no live session (lost token).
                        guard let session = sessions.first(where: { $0.id == server.id }) else { continue }
                        let hidden = hiddenCollectionIDs[server.id] ?? []
                        taskGroup.addTask {
                            await jellyfinGroup(
                                session: session,
                                index: index,
                                hiddenCollectionIDs: hidden,
                                snapshots: snapshots,
                                jellyfinRepo: jellyfinRepo
                            )
                        }
                    case .smb(let data):
                        // Built here, not in a child task: an SMB group is a pure mapping over the
                        // user's saved share list with no I/O, so there's nothing to overlap — and
                        // `smbGroup` is a synchronous MainActor-isolated call, which a child task
                        // can't make.
                        let group = smbGroup(id: server.id, data: data)
                        taskGroup.addTask { (index, group, nil) }
                    }
                }
                var out: [(index: Int, group: LibraryGroup?, failed: MediaSourceID?)] = []
                for await result in taskGroup {
                    out.append((result.0, result.1, result.2))
                }
                return out
            }

        // A failed server falls back to what it already contributes on screen (its cached, or
        // previously loaded, libraries) so a dropped connection doesn't empty a section the user
        // is looking at. Substituted before assembly so the carried group sorts into its normal
        // place; the failed id is left alone so recovery still re-pulls it.
        let restored = resolved.map { entry in
            guard entry.group == nil, let failed = entry.failed,
                  let carried = previous.first(where: { $0.id == failed }) else { return entry }
            return (index: entry.index, group: carried, failed: entry.failed)
        }

        let groups = assemble(restored)

        // Only Jellyfin sources can fail (SMB resolves offline from the saved share list), so the
        // names come from the sessions — walked in `servers` order so the list reads in the same
        // order as the sidebar rather than in whatever order the fan-out finished.
        let failedIDs = Set(restored.compactMap(\.failed))
        let failedNames = servers.compactMap { server -> String? in
            guard failedIDs.contains(.jellyfin(server.id)) else { return nil }
            return sessions.first { $0.id == server.id }?.serverName
        }
        return Outcome(groups: groups, failedSourceIDs: failedIDs, failedSourceNames: failedNames)
    }

    /// The same grouped list, built entirely from the on-disk snapshot of each Jellyfin server's
    /// last listing — no network. The roots put this up first and reveal on it, then run the real
    /// `resolve` behind it.
    ///
    /// Returns an empty array when no Jellyfin server has a cached listing: SMB alone resolves
    /// offline anyway, so hydrating it buys nothing and would only make the roots reveal on a
    /// half-list they were about to get for free. The hidden-libraries and browsable filters are
    /// applied here rather than baked into the snapshot, so a "Visible Libraries" edit takes
    /// effect on the cached list too.
    static func cached(
        sessions: [Session],
        servers: [PersistedServer],
        hiddenCollectionIDs: [ServerID: Set<String>] = [:],
        snapshots: SnapshotStore
    ) async -> [LibraryGroup] {
        var resolved: [(index: Int, group: LibraryGroup?, failed: MediaSourceID?)] = []
        var hasCachedJellyfin = false
        for (index, server) in servers.enumerated() {
            switch server.kind {
            case .jellyfin:
                guard let session = sessions.first(where: { $0.id == server.id }),
                      let collections = await snapshots.libraries(forServerID: server.id.rawValue) else { continue }
                hasCachedJellyfin = true
                resolved.append((index, group(
                    from: collections,
                    source: .jellyfin(session),
                    hiddenCollectionIDs: hiddenCollectionIDs[server.id] ?? []
                ), nil))
            case .smb(let data):
                resolved.append((index, smbGroup(id: server.id, data: data), nil))
            }
        }
        return hasCachedJellyfin ? assemble(resolved) : []
    }

    /// One Jellyfin server's group. Returns a nil group (and a non-nil failed id) when the listing
    /// throws; returns nil for both when the server legitimately exposes no visible libraries — an
    /// empty group would render as a titled section with nothing under it.
    private static func jellyfinGroup(
        session: Session,
        index: Int,
        hiddenCollectionIDs: Set<String>,
        snapshots: SnapshotStore?,
        jellyfinRepo: @escaping @Sendable (Session) async -> any MediaRepository
    ) async -> (Int, LibraryGroup?, MediaSourceID?) {
        let source: LibrarySource = .jellyfin(session)
        do {
            let collections = try await jellyfinRepo(session).collections()
            // Cached RAW, before the filters below: they're local, cheap, and user-editable, so
            // baking them in would make a "Visible Libraries" change need a network round trip to
            // take effect on the cached list.
            await snapshots?.setLibraries(collections, forServerID: session.id.rawValue)
            return (index, group(from: collections, source: source, hiddenCollectionIDs: hiddenCollectionIDs), nil)
        } catch {
            // Offline / server down: contribute no group, but flag the source so the roots
            // distinguish it from an empty server and re-pull just this one on reconnect.
            return (index, nil, source.sourceID)
        }
    }

    /// One server's listing, filtered down to what this app will show. Shared by the live and the
    /// cached path so a library hidden on one is hidden on the other.
    private static func group(
        from collections: [MediaCollection],
        source: LibrarySource,
        hiddenCollectionIDs: Set<String>
    ) -> LibraryGroup? {
        let entries = collections
            // De-selected libraries (the server's "Visible Libraries" screen) drop out of every root.
            .filter { !hiddenCollectionIDs.contains($0.id.rawValue) }
            // Collections this app can't browse (music, photos, books — anything that isn't
            // movies or shows). This filter used to live ONLY in the iPhone card list, so the
            // iPad sidebar and tvOS root listed unopenable libraries the iPhone hid — a
            // platform drift in logic, which the resolver being the single source now fixes.
            .filter { $0.collectionType.isBrowsable }
            .map { LibraryEntry(source: source, collection: $0) }
        return entries.isEmpty ? nil : LibraryGroup(source: source, entries: entries)
    }

    /// Jellyfin sections first, then SMB (`sectionRank`), and within a rank the order the user
    /// added them — `index` is the position in `servers`, so the tie-break restores add order
    /// after a concurrent fan-out returned out of order.
    private static func assemble(
        _ resolved: [(index: Int, group: LibraryGroup?, failed: MediaSourceID?)]
    ) -> [LibraryGroup] {
        resolved
            .compactMap { entry in entry.group.map { (index: entry.index, group: $0) } }
            .sorted { lhs, rhs in
                let lRank = lhs.group.source.sectionRank
                let rRank = rhs.group.source.sectionRank
                return lRank == rRank ? lhs.index < rhs.index : lRank < rRank
            }
            .map(\.group)
    }

    /// One SMB server's group — one entry per selected share. The share name is the collection
    /// identity (round-tripped into the grid scope) and the display name; `.movies` mirrors the
    /// flat file-browse grid.
    private static func smbGroup(id: ServerID, data: SMBServerData) -> LibraryGroup? {
        guard !data.shares.isEmpty else { return nil }
        let source: LibrarySource = .smb(SMBServerRef(id: id, data: data))
        let entries = data.shares.map { share in
            LibraryEntry(
                source: source,
                collection: MediaCollection(
                    id: CollectionID(rawValue: share),
                    name: share,
                    collectionType: .movies,
                    primaryTag: nil
                )
            )
        }
        return LibraryGroup(source: source, entries: entries)
    }
}
