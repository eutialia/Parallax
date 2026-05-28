import Foundation
import Nuke

public actor ImagePipelineFactory {
    private let identityProvider: DeviceIdentityProvider
    // Resolved once and reused — the provider returns the SAME persisted
    // deviceID the auth layer uses, so image traffic and API traffic present
    // one consistent device identity instead of a per-launch random UUID.
    private var cachedIdentity: DeviceIdentity?
    // Store (token, pipeline) so we can detect token rotation.
    private var pipelinesByServer: [ServerID: (token: String, pipeline: ImagePipeline)] = [:]

    public init(identityProvider: DeviceIdentityProvider) {
        self.identityProvider = identityProvider
    }

    public func pipeline(for session: Session) async -> ImagePipeline {
        if let entry = pipelinesByServer[session.id], entry.token == session.accessToken {
            return entry.pipeline
        }
        // Either no cached pipeline OR token has rotated (sign-out + sign-in
        // to same server). Drop our reference to any stale pipeline so it (and
        // its old-token URLSession) can be torn down once the view layer
        // switches over and cancels the in-flight tasks bound to it.
        pipelinesByServer[session.id] = nil
        let identity = await resolveIdentity()
        let pipeline = Self.makePipeline(session: session, identity: identity)
        pipelinesByServer[session.id] = (session.accessToken, pipeline)
        return pipeline
    }

    private func resolveIdentity() async -> DeviceIdentity {
        if let cachedIdentity { return cachedIdentity }
        let identity = await identityProvider.current()
        cachedIdentity = identity
        return identity
    }

    nonisolated static func authorizationHeader(identity: DeviceIdentity, token: String) -> String {
        // Jellyfin's MediaBrowser auth header — token is included on every
        // request, not just login. Image endpoints reject anonymous reads
        // when the server is configured to require auth.
        "MediaBrowser " + [
            "Client=\"\(identity.client)\"",
            "Device=\"\(identity.deviceName)\"",
            "DeviceId=\"\(identity.deviceID)\"",
            "Version=\"\(identity.version)\"",
            "Token=\"\(token)\"",
        ].joined(separator: ", ")
    }

    nonisolated private static func makePipeline(session: Session, identity: DeviceIdentity) -> ImagePipeline {
        let urlSessionConfig = URLSessionConfiguration.default
        urlSessionConfig.httpAdditionalHeaders = [
            "X-Emby-Authorization": authorizationHeader(identity: identity, token: session.accessToken),
        ]
        urlSessionConfig.requestCachePolicy = .useProtocolCachePolicy
        urlSessionConfig.timeoutIntervalForRequest = 30

        let dataLoader = DataLoader(configuration: urlSessionConfig)

        var pipelineConfig = ImagePipeline.Configuration.withDataCache(
            name: "com.lhdev.parallax.images.\(session.id.rawValue)"
        )
        pipelineConfig.dataLoader = dataLoader
        return ImagePipeline(configuration: pipelineConfig)
    }
}
