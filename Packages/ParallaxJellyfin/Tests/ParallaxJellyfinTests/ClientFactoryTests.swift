import Foundation
import Testing
import JellyfinAPI
import ParallaxCore
@testable import ParallaxJellyfin

/// The three factories are the ONLY place a real client is constructed, so they own two facts the
/// clients themselves can't: that the persisted device identity is resolved and threaded in
/// (a per-launch random id would break the server's device attribution, and with it the
/// `deviceId`-scoped transcode kill), and that the token-rejection sink reaches the client's
/// response validator. Both are proven by driving the built client over a stub transport.
@Suite("Jellyfin client factories")
struct ClientFactoryTests {

    private func identityProvider(deviceName: String = "Factory Test") -> DeviceIdentityProvider {
        let (settings, _) = JellyfinFixtures.settingsStore("ClientFactoryTests")
        return DeviceIdentityProvider(
            client: "Parallax",
            deviceName: deviceName,
            version: "9.9.9",
            settings: settings
        )
    }

    /// Every client built from one provider must present the same device id — the whole reason the
    /// provider persists it.
    @Test("All three factories stamp requests with the provider's persisted device identity")
    func factoriesShareOneDeviceIdentity() async throws {
        let provider = identityProvider()
        let expected = await provider.current()

        let authStub = StubHTTPTransport()
        authStub.always(.noContent)
        let authClient = await DefaultJellyfinClientFactory(
            identityProvider: provider,
            sessionConfiguration: authStub.configuration
        ).make(serverURL: authStub.baseURL)
        try await authClient.signOut(accessToken: "tok-1")

        let libraryStub = StubHTTPTransport()
        libraryStub.always(.json("{}"))
        let libraryClient = await DefaultJellyfinLibraryClientFactory(
            identityProvider: provider,
            sessionConfiguration: libraryStub.configuration
        ).make(for: JellyfinFixtures.session(serverURL: libraryStub.baseURL))
        _ = try await libraryClient.getCollections()

        let playbackStub = StubHTTPTransport()
        playbackStub.always(.noContent)
        let playbackClient = await DefaultJellyfinPlaybackClientFactory(
            identityProvider: provider,
            sessionConfiguration: playbackStub.configuration
        ).make(for: JellyfinFixtures.session(serverURL: playbackStub.baseURL))
        try await playbackClient.pingSession(playSessionID: "ps-1")

        for stub in [authStub, libraryStub, playbackStub] {
            let authorization = try stub.onlyExchange().headers["Authorization"] ?? ""
            #expect(authorization.contains("DeviceId=\(expected.deviceID)"))
            #expect(authorization.contains("Version=9.9.9"))
        }
    }

    @Test("The auth factory points the client at the requested server")
    func authFactoryUsesRequestedServer() async {
        let url = URL(string: "https://requested.example.com")!
        let client = await DefaultJellyfinClientFactory(identityProvider: identityProvider())
            .make(serverURL: url)
        #expect(client.serverURL == url)
    }

    /// Browse and playback share ONE sink so a revoked token is reported once, wherever it's
    /// noticed first. A factory that dropped the closure would leave the server looking connected
    /// with silently empty libraries — the exact bug the sink exists to end.
    @Test("Both session factories thread the token-rejection sink into their client")
    func sessionFactoriesForwardTokenRejection() async throws {
        let provider = identityProvider()
        let reported = ReportedServerIDs()
        let session = JellyfinFixtures.session(id: "s-reject")

        let libraryStub = StubHTTPTransport()
        libraryStub.always(.json("{}", status: 401))
        let libraryClient = await DefaultJellyfinLibraryClientFactory(
            identityProvider: provider,
            onTokenRejected: { reported.record($0) },
            sessionConfiguration: libraryStub.configuration
        ).make(for: JellyfinFixtures.session(id: "s-reject", serverURL: libraryStub.baseURL))
        await #expect(throws: AppError.self) { _ = try await libraryClient.getCollections() }

        let playbackStub = StubHTTPTransport()
        playbackStub.always(.json("{}", status: 401))
        let playbackClient = await DefaultJellyfinPlaybackClientFactory(
            identityProvider: provider,
            onTokenRejected: { reported.record($0) },
            sessionConfiguration: playbackStub.configuration
        ).make(for: JellyfinFixtures.session(id: "s-reject", serverURL: playbackStub.baseURL))
        await #expect(throws: AppError.self) { try await playbackClient.pingSession(playSessionID: "ps-1") }

        #expect(reported.ids == [session.id, session.id])
    }

    /// Omitting the sink is the previews/tests path: the 401 still fails the call, but nothing is
    /// signed out.
    @Test("Omitting the sink leaves the client without a rejection reporter")
    func sinkIsOptional() async throws {
        let stub = StubHTTPTransport()
        stub.always(.json("{}", status: 401))
        let client = await DefaultJellyfinLibraryClientFactory(
            identityProvider: identityProvider(),
            sessionConfiguration: stub.configuration
        ).make(for: JellyfinFixtures.session(serverURL: stub.baseURL))

        await #expect(throws: (any Error).self) { _ = try await client.getCollections() }
        // Nothing to assert about a sink that isn't there — the point is that the call still
        // completes as a failure instead of trapping on a missing handler.
        #expect(stub.exchanges.count == 1)
    }
}
