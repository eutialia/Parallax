import Foundation
import Testing
import JellyfinAPI
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("SessionManager Quick Connect")
struct SessionManagerQuickConnectTests {
    private func make() -> (SessionManager, ServerStore, FakeJellyfinClientFactory) {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(defaults: defaults)
        let keychain = Keychain(service: "com.lhdev.parallax.tests.\(suite)")
        let store = ServerStore(settings: settings, keychain: keychain)
        let factory = FakeJellyfinClientFactory()
        let manager = SessionManager(serverStore: store, factory: factory)
        return (manager, store, factory)
    }

    private func successAuthResult() -> AuthenticationResult {
        var user = UserDto()
        user.id = "user-1"
        user.name = "alice"
        var result = AuthenticationResult()
        result.accessToken = "tok-qc"
        result.serverID = "server-qc"
        result.user = user
        return result
    }

    private func publicInfo() -> PublicSystemInfo {
        var info = PublicSystemInfo()
        info.serverName = "Cinema"
        info.id = "server-qc"
        return info
    }

    @Test("Full Quick Connect happy path: code → signedIn")
    func happyPath() async throws {
        let (manager, store, factory) = make()
        let url = URL(string: "https://jellyfin.example.com")!
        let client = factory.client(for: url)
        client.quickConnectEventsToYield = [
            .success(.polling(code: "AB12")),
            .success(.authenticated(secret: "secret-xyz")),
        ]
        client.quickConnectSignInResult = .success(successAuthResult())
        client.publicSystemInfoResult = .success(publicInfo())

        var statuses: [QuickConnectStatus] = []
        let stream = await manager.signInWithQuickConnect(server: url)
        for await status in stream {
            statuses.append(status)
        }

        #expect(statuses.contains(.waitingForCode))
        #expect(statuses.contains(.polling(code: "AB12")))
        if case .signedIn(let session) = statuses.last {
            #expect(session.serverName == "Cinema")
            #expect(session.accessToken == "tok-qc")
        } else {
            Issue.record("expected last status to be .signedIn, got \(String(describing: statuses.last))")
        }

        let stored = await store.sessions
        #expect(stored.count == 1)
    }

    @Test("maxPollingHit error yields .expired and does not persist a session")
    func expired() async throws {
        struct FakeQuickConnectError: Error, CustomStringConvertible {
            var description: String { "maxPollingHit" }
        }
        let (manager, store, factory) = make()
        let url = URL(string: "https://jellyfin.example.com")!
        let client = factory.client(for: url)
        client.quickConnectEventsToYield = [
            .success(.polling(code: "AB12")),
            .failure(FakeQuickConnectError()),
        ]

        var statuses: [QuickConnectStatus] = []
        for await status in await manager.signInWithQuickConnect(server: url) {
            statuses.append(status)
        }

        #expect(statuses.contains(.expired))
        #expect(statuses.last == .expired)
        let stored = await store.sessions
        #expect(stored.isEmpty)
    }

    @Test("retrievingCodeFailed yields .rejected")
    func rejected() async throws {
        struct FakeQuickConnectError: Error, CustomStringConvertible {
            var description: String { "retrievingCodeFailed" }
        }
        let (manager, _, factory) = make()
        let url = URL(string: "https://jellyfin.example.com")!
        let client = factory.client(for: url)
        client.quickConnectEventsToYield = [
            .failure(FakeQuickConnectError()),
        ]

        var statuses: [QuickConnectStatus] = []
        for await status in await manager.signInWithQuickConnect(server: url) {
            statuses.append(status)
        }

        #expect(statuses.last == .rejected || statuses.contains(.rejected))
    }
}
