import ParallaxCore
import ParallaxJellyfin

/// Builds the merged library list shown by both navigation roots (iPad sidebar +
/// tvOS focus root). Source-symmetric and view-free so it's unit-testable: the
/// roots feed it the active Jellyfin session + the configured SMB servers, and it
/// returns one source-tagged `LibraryEntry` per collection across every source.
enum MergedLibrary {
    /// The resolved library list plus a recovery signal for the nav roots.
    struct Outcome {
        /// The merged, source-tagged entries (Jellyfin collections first, then one per SMB share).
        var entries: [LibraryEntry]
        /// `true` only when a Jellyfin session was provided AND its `collections()` call threw —
        /// the Jellyfin half is missing because the fetch failed (offline / server down), not
        /// because the server legitimately has no visible libraries. The roots gate offline
        /// auto-recovery on this. `false` for a successful (even empty / all-hidden) fetch and for
        /// a nil session (SMB-only) — neither is a stall, so neither should keep re-fetching.
        var jellyfinCollectionsFailed: Bool
    }

    /// The merged library entries: the active Jellyfin session's collections, then one entry per
    /// configured SMB server's shares, each tagged with its `LibrarySource` so the UI dispatches
    /// taps by source. The two halves source their list very differently, which is why they behave
    /// differently offline:
    /// - Jellyfin: a LIVE request (`collections()` → `GET /Users/{id}/Views`). The collection list
    ///   is server-owned state the app never persists, so enumerating it needs the network — this is
    ///   the half that fails offline (the sidebar's Jellyfin libraries disappear).
    /// - SMB: network-free — the shares are the user's saved selection (persisted in `SMBServerData`),
    ///   so each maps straight to a `LibraryEntry` with no listing. They always resolve, online or
    ///   not; the network hit is deferred to opening a share.
    ///
    /// A Jellyfin source whose `collections()` throws contributes nothing and does not abort the
    /// SMB entries — a flaky/unreachable server can't blank the configured shares — but the throw is
    /// reported via `Outcome.jellyfinCollectionsFailed` so the roots can re-resolve on reconnect.
    static func resolve(
        jellyfinSession: Session?,
        smbServers: [PersistedServer],
        hiddenJellyfinCollectionIDs: Set<String> = [],
        jellyfinRepo: @Sendable (Session) async -> any MediaRepository
    ) async -> Outcome {
        var entries: [LibraryEntry] = []
        var jellyfinCollectionsFailed = false

        if let session = jellyfinSession {
            let source: LibrarySource = .jellyfin(session)
            do {
                let collections = try await jellyfinRepo(session).collections()
                // De-selected libraries (the server's "Visible Libraries" screen) drop out of every root.
                entries += collections
                    .filter { !hiddenJellyfinCollectionIDs.contains($0.id.rawValue) }
                    .map { LibraryEntry(source: source, collection: $0) }
            } catch {
                // Offline / server down: contribute no Jellyfin entries, but flag the failure so the
                // roots distinguish it from an empty server and recover once connectivity returns.
                jellyfinCollectionsFailed = true
            }
        }

        for server in smbServers {
            guard case .smb(let data) = server.kind else { continue }
            let source: LibrarySource = .smb(SMBServerRef(id: server.id, data: data))
            // One sidebar entry per share. The share name is the collection identity (round-tripped
            // into the grid scope) and the display name; `.movies` mirrors the flat file-browse grid.
            entries += data.shares.map { share in
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
        }

        return Outcome(entries: entries, jellyfinCollectionsFailed: jellyfinCollectionsFailed)
    }
}
