import Foundation

public protocol JellyfinClientFactory: Sendable {
    func make(serverURL: URL) async -> JellyfinAuthClient
}

public actor DefaultJellyfinClientFactory: JellyfinClientFactory {
    private let identityProvider: DeviceIdentityProvider
    /// The transport clients built here run on. Defaulted to `.default` so production is
    /// unchanged; tests hand in a configuration carrying a stub `URLProtocol`.
    private let sessionConfiguration: URLSessionConfiguration

    public init(
        identityProvider: DeviceIdentityProvider,
        sessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.identityProvider = identityProvider
        self.sessionConfiguration = sessionConfiguration
    }

    public func make(serverURL: URL) async -> JellyfinAuthClient {
        let identity = await identityProvider.current()
        return DefaultJellyfinAuthClient(
            serverURL: serverURL,
            identity: identity,
            sessionConfiguration: sessionConfiguration
        )
    }
}
