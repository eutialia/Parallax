import ParallaxCore
import ParallaxJellyfin

/// Builds the merged library list shown by both navigation roots (iPad sidebar +
/// tvOS focus root). Source-symmetric and view-free so it's unit-testable: the
/// roots feed it the active Jellyfin session + the configured SMB servers, and it
/// returns one source-tagged `LibraryEntry` per collection across every source.
enum MergedLibrary {
    /// The merged library entries: the active Jellyfin session's collections, then one entry per
    /// configured SMB server's shares, each tagged with its `LibrarySource` so the UI dispatches
    /// taps by source. Both halves are network-free: Jellyfin collection enumeration is a cheap
    /// cached read, and each SMB share maps straight to a `LibraryEntry` (no listing) — the
    /// network hit is deferred to opening a grid.
    ///
    /// A Jellyfin source whose `collections()` throws contributes nothing and does not abort the
    /// SMB entries (`try?`) — a flaky server can't blank the configured shares.
    static func entries(
        jellyfinSession: Session?,
        smbServers: [PersistedServer],
        hiddenJellyfinCollectionIDs: Set<String> = [],
        jellyfinRepo: @Sendable (Session) async -> any MediaRepository
    ) async -> [LibraryEntry] {
        var entries: [LibraryEntry] = []

        if let session = jellyfinSession {
            let source: LibrarySource = .jellyfin(session)
            let collections = (try? await jellyfinRepo(session).collections()) ?? []
            // De-selected libraries (the server's "Visible Libraries" screen) drop out of every root.
            entries += collections
                .filter { !hiddenJellyfinCollectionIDs.contains($0.id.rawValue) }
                .map { LibraryEntry(source: source, collection: $0) }
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

        return entries
    }
}
