import Foundation
import Testing
import ParallaxCore
@testable import ParallaxJellyfin
import ParallaxJellyfinTestSupport

/// An unreachable server never answers: `URLSession` throws a `URLError`, which the SDK-backed
/// client hands to `ErrorMapping` as `AppError.network`. An HTTP status takes the `.server` branch
/// instead, so a fake that answers 503 would exercise the wrong one.
@Suite("FakeJellyfinServer offline")
struct FakeServerOfflineTests {

    private func repository(for den: FakeJellyfinServer) -> LibraryRepository {
        LibraryRepository(client: DefaultJellyfinLibraryClient(
            session: den.session(signedInAs: "ana"),
            identity: JellyfinFixtures.identity(),
            onTokenRejected: { _ in },
            sessionConfiguration: StubHTTPTransport.configuration
        ))
    }

    @Test("a server that went offline fails a real client with a transport URLError, and serves again once back")
    func offlineIsATransportFailure() async throws {
        let den = FakeJellyfinServer(name: "Den").user("ana").library("Films")
        let repository = repository(for: den)
        #expect(try await repository.collections().map(\.name) == ["Films"])

        den.goOffline()
        let error = await #expect(throws: AppError.self) { try await repository.collections() }

        guard case .network(let urlError)? = error else {
            Issue.record("expected AppError.network, got \(String(describing: error))")
            return
        }
        #expect(urlError.code == .cannotConnectToHost)
        #expect(error?.userMessage == "Couldn't find your server. Check the URL, or make sure it's online.")

        den.comeBackOnline()
        #expect(try await repository.collections().map(\.name) == ["Films"])
    }

    @Test("a transport failure reply reaches the client as that URLError code", arguments: [
        URLError.Code.timedOut, .notConnectedToInternet, .cannotConnectToHost,
    ])
    func replyCarriesTheCode(code: URLError.Code) async throws {
        let stub = StubHTTPTransport()
        stub.always(.failure(code))
        let client = DefaultJellyfinLibraryClient(
            session: JellyfinFixtures.session(serverURL: stub.baseURL),
            identity: JellyfinFixtures.identity(),
            onTokenRejected: { _ in },
            sessionConfiguration: stub.configuration
        )

        let error = await #expect(throws: URLError.self) { try await client.getCollections() }

        #expect(error?.code == code)
    }
}
