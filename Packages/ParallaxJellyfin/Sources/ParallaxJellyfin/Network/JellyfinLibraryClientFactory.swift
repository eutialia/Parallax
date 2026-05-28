import Foundation

public protocol JellyfinLibraryClientFactory: Sendable {
    func make(for session: Session) async -> JellyfinLibraryClient
}

public actor DefaultJellyfinLibraryClientFactory: JellyfinLibraryClientFactory {
    private let identityProvider: DeviceIdentityProvider

    public init(identityProvider: DeviceIdentityProvider) {
        self.identityProvider = identityProvider
    }

    public func make(for session: Session) async -> JellyfinLibraryClient {
        let identity = await identityProvider.current()
        return DefaultJellyfinLibraryClient(session: session, identity: identity)
    }
}
