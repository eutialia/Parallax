import Foundation

public protocol JellyfinLibraryClientFactory: Sendable {
    func make(for session: Session) async -> JellyfinLibraryClient
}

public actor DefaultJellyfinLibraryClientFactory: JellyfinLibraryClientFactory {
    private let identityProvider: DeviceIdentityProvider
    private let onTokenRejected: (@Sendable (ServerID) -> Void)?

    /// - Parameter onTokenRejected: invoked with the server whose access token the server
    ///   rejected (HTTP 401). The app hands in a sink that drops that session so the server
    ///   surfaces as signed-out rather than silently returning nothing. Omit to opt out.
    public init(
        identityProvider: DeviceIdentityProvider,
        onTokenRejected: (@Sendable (ServerID) -> Void)? = nil
    ) {
        self.identityProvider = identityProvider
        self.onTokenRejected = onTokenRejected
    }

    public func make(for session: Session) async -> JellyfinLibraryClient {
        let identity = await identityProvider.current()
        return DefaultJellyfinLibraryClient(
            session: session,
            identity: identity,
            onTokenRejected: onTokenRejected
        )
    }
}
