import Foundation
import Nuke

public actor ImagePipelineFactory {
    private let identity: DeviceIdentity
    private var pipelinesByServer: [ServerID: ImagePipeline] = [:]

    public init(identity: DeviceIdentity) {
        self.identity = identity
    }

    public func pipeline(for session: Session) -> ImagePipeline {
        if let existing = pipelinesByServer[session.id] { return existing }
        let pipeline = Self.makePipeline(session: session, identity: identity)
        pipelinesByServer[session.id] = pipeline
        return pipeline
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
