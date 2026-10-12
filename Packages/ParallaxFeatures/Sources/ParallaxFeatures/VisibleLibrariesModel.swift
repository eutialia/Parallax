import Foundation
import Observation
import ParallaxCore
import ParallaxJellyfin

/// The "Visible Libraries" picker's state: a Jellyfin server's libraries and which of them the user
/// has hidden. The hidden set persists per server (`ServerStore.setHiddenCollectionIDs`) and bumps
/// the router's library revision, so the merged library at every nav root drops hidden libraries live.
@Observable
@MainActor
public final class VisibleLibrariesModel {
    public private(set) var collections: [MediaCollection] = []
    public private(set) var hidden: Set<String> = []
    public private(set) var isLoading = true
    public private(set) var loadError: String?

    private let session: Session
    private let app: AppModel

    public init(session: Session, app: AppModel) {
        self.session = session
        self.app = app
    }

    public func load() async {
        isLoading = true
        loadError = nil
        hidden = await app.services.serverStore.hiddenCollectionIDs(for: session.id)
        do {
            collections = try await app.services.jellyfinLibraryRepoFactory(session).collections()
        } catch {
            loadError = "Couldn’t load this server’s libraries."
        }
        isLoading = false
    }

    public func toggle(_ collection: MediaCollection) async {
        let id = collection.id.rawValue
        let wasHidden = hidden.contains(id)
        if wasHidden { hidden.remove(id) } else { hidden.insert(id) }
        do {
            try await app.services.serverStore.setHiddenCollectionIDs(hidden, for: session.id)
            // Rebuild the merged library wherever it's shown, so the change is immediate.
            app.router.bumpLibraryRevision()
        } catch {
            // Persist failed — revert the optimistic toggle so the checkmark matches what's stored,
            // and DON'T bump the revision (the roots would re-read the unchanged set and diverge from
            // this screen). The reverted checkmark is the feedback that the change didn't take.
            if wasHidden { hidden.insert(id) } else { hidden.remove(id) }
        }
    }
}
