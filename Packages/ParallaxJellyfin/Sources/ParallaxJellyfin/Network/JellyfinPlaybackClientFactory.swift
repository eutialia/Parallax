import Foundation

public protocol JellyfinPlaybackClientFactory: Sendable {
    func make(for session: Session) async -> JellyfinPlaybackClient
}

public actor DefaultJellyfinPlaybackClientFactory: JellyfinPlaybackClientFactory {
    private let identityProvider: DeviceIdentityProvider

    public init(identityProvider: DeviceIdentityProvider) {
        self.identityProvider = identityProvider
    }

    public func make(for session: Session) async -> JellyfinPlaybackClient {
        let identity = await identityProvider.current()
        return DefaultJellyfinPlaybackClient(session: session, identity: identity)
    }
}
