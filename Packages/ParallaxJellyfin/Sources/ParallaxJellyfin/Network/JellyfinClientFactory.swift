import Foundation

public protocol JellyfinClientFactory: Sendable {
    func make(serverURL: URL) async -> JellyfinAuthClient
}

public actor DefaultJellyfinClientFactory: JellyfinClientFactory {
    private let identityProvider: DeviceIdentityProvider
    /// The transport clients built here run on. Defaulted to `.default` so production is
    /// unchanged; tests hand in a configuration carrying a stub `URLProtocol`.
    private let sessionConfiguration: URLSessionConfiguration
    private let clock: any Clock<Duration>

    public init(
        identityProvider: DeviceIdentityProvider,
        sessionConfiguration: URLSessionConfiguration = .default,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.identityProvider = identityProvider
        self.sessionConfiguration = sessionConfiguration
        self.clock = clock
    }

    public func make(serverURL: URL) async -> JellyfinAuthClient {
        let identity = await identityProvider.current()
        return DefaultJellyfinAuthClient(
            serverURL: serverURL,
            identity: identity,
            sessionConfiguration: sessionConfiguration,
            clock: clock
        )
    }
}
