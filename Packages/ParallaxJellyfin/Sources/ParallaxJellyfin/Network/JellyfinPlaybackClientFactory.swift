import Foundation

public protocol JellyfinPlaybackClientFactory: Sendable {
    func make(for session: Session) async -> JellyfinPlaybackClient
}

public actor DefaultJellyfinPlaybackClientFactory: JellyfinPlaybackClientFactory {
    private let identityProvider: DeviceIdentityProvider
    private let onTokenRejected: (@Sendable (ServerID) -> Void)?

    /// - Parameter onTokenRejected: see `DefaultJellyfinLibraryClientFactory`. Playback shares
    ///   the same sink so one revoked token is reported once, wherever it's noticed first.
    public init(
        identityProvider: DeviceIdentityProvider,
        onTokenRejected: (@Sendable (ServerID) -> Void)? = nil
    ) {
        self.identityProvider = identityProvider
        self.onTokenRejected = onTokenRejected
    }

    public func make(for session: Session) async -> JellyfinPlaybackClient {
        let identity = await identityProvider.current()
        return DefaultJellyfinPlaybackClient(
            session: session,
            identity: identity,
            onTokenRejected: onTokenRejected
        )
    }
}
