import Foundation

/// Vends one `LibraryRepository` per server, reused across every screen.
///
/// Without this, each Home/Library/Detail/Search screen calls the repo factory
/// from its own `.task` and gets a fresh `LibraryRepository` + backing
/// `JellyfinLibraryClient` — N duplicate actors per session, plus duplicate
/// network calls for the same item when screens overlap. Caching by server
/// collapses that to one repo per server, rebuilt only when the access token
/// rotates (sign-out + sign-in to the same server).
public actor LibraryRepositoryStore {
    private let clientFactory: JellyfinLibraryClientFactory
    // (token, repo) so a rotated token forces a rebuild with a fresh client.
    private var reposByServer: [ServerID: (token: String, repo: LibraryRepository)] = [:]

    public init(clientFactory: JellyfinLibraryClientFactory) {
        self.clientFactory = clientFactory
    }

    public func repository(for session: Session) async -> LibraryRepository {
        if let entry = reposByServer[session.id], entry.token == session.accessToken {
            return entry.repo
        }
        let client = await clientFactory.make(for: session)
        let repo = LibraryRepository(session: session, client: client)
        reposByServer[session.id] = (session.accessToken, repo)
        return repo
    }
}
