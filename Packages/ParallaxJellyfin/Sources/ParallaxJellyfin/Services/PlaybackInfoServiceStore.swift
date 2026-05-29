import Foundation

/// Vends one `PlaybackInfoService` per server, reused across every Play tap.
///
/// Mirrors `LibraryRepositoryStore`: without it, each playback start spins up
/// a fresh service + backing `JellyfinPlaybackClient`. Caching by server
/// collapses that to one service per server, rebuilt only when the access
/// token rotates (sign-out + sign-in to the same server).
public actor PlaybackInfoServiceStore {
    private let clientFactory: JellyfinPlaybackClientFactory
    // (token, service) so a rotated token forces a rebuild with a fresh client.
    private var servicesByServer: [ServerID: (token: String, service: PlaybackInfoService)] = [:]

    public init(clientFactory: JellyfinPlaybackClientFactory) {
        self.clientFactory = clientFactory
    }

    public func service(for session: Session) async -> PlaybackInfoService {
        if let entry = servicesByServer[session.id], entry.token == session.accessToken {
            return entry.service
        }
        let client = await clientFactory.make(for: session)
        let service = PlaybackInfoService(client: client)
        servicesByServer[session.id] = (session.accessToken, service)
        return service
    }
}
