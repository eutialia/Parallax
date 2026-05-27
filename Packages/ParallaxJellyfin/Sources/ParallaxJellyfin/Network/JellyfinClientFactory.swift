import Foundation

public protocol JellyfinClientFactory: Sendable {
    func make(serverURL: URL) async -> JellyfinAuthClient
}

public actor DefaultJellyfinClientFactory: JellyfinClientFactory {
    private let identityProvider: DeviceIdentityProvider

    public init(identityProvider: DeviceIdentityProvider) {
        self.identityProvider = identityProvider
    }

    public func make(serverURL: URL) async -> JellyfinAuthClient {
        let identity = await identityProvider.current()
        return DefaultJellyfinAuthClient(serverURL: serverURL, identity: identity)
    }
}
