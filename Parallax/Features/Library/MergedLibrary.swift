import ParallaxCore
import ParallaxJellyfin

/// Builds the merged library list shown by both navigation roots (iPad sidebar +
/// tvOS focus root). Source-symmetric and view-free so it's unit-testable: the
/// roots feed it the active Jellyfin session + the configured SMB servers, and it
/// returns one source-tagged `LibraryEntry` per collection across every source.
enum MergedLibrary {
    /// The merged library entries: the active Jellyfin session's collections, then every
    /// configured SMB server's collections, each tagged with its `LibrarySource` so the UI
    /// dispatches taps by source. Collection enumeration is cheap (SMB `collections()` maps
    /// roots without a network round-trip); the network hit is deferred to opening a grid.
    ///
    /// A source whose `collections()` throws contributes nothing and does not abort the
    /// others (`try?` per source) — a flaky SMB server can't blank the Jellyfin libraries.
    static func entries(
        jellyfinSession: Session?,
        smbServers: [PersistedServer],
        hiddenJellyfinCollectionIDs: Set<String> = [],
        repoFactory: @Sendable (LibrarySource) async -> any MediaRepository
    ) async -> [LibraryEntry] {
        var entries: [LibraryEntry] = []

        if let session = jellyfinSession {
            let source: LibrarySource = .jellyfin(session)
            let collections = (try? await repoFactory(source).collections()) ?? []
            // De-selected libraries (the server's "Visible Libraries" screen) drop out of every root.
            entries += collections
                .filter { !hiddenJellyfinCollectionIDs.contains($0.id.rawValue) }
                .map { LibraryEntry(source: source, collection: $0) }
        }

        for server in smbServers {
            guard case .smb(let data) = server.kind else { continue }
            let source: LibrarySource = .smb(SMBServerRef(id: server.id, data: data))
            let collections = (try? await repoFactory(source).collections()) ?? []
            entries += collections.map { LibraryEntry(source: source, collection: $0) }
        }

        return entries
    }
}
