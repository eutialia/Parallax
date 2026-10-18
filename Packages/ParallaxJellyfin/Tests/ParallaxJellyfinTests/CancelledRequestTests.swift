import Foundation
import Testing
import ParallaxCoreTestSupport
@testable import ParallaxJellyfin
import ParallaxJellyfinTestSupport

/// A cancelled caller stops waiting with `CancellationError`, and the cancellation never reaches
/// Get, whose `DataLoader` traps when a request starts on an already-cancelled task.
@Suite("Jellyfin requests under cancellation")
struct CancelledRequestTests {

    private func makeRepository(stub: StubHTTPTransport) -> LibraryRepository {
        LibraryRepository(client: DefaultJellyfinLibraryClient(
            session: JellyfinFixtures.session(id: "s1", token: "tok-1", serverURL: stub.baseURL, userID: "u1"),
            identity: JellyfinFixtures.identity(),
            onTokenRejected: { _ in },
            sessionConfiguration: stub.configuration
        ))
    }

    @Test("A request from an already-cancelled task throws CancellationError and never goes out")
    func alreadyCancelled() async throws {
        let stub = StubHTTPTransport()
        let repository = makeRepository(stub: stub)

        let call = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await repository.collections()
        }

        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(stub.exchanges.isEmpty)
    }

    @Test("Cancelling a request in flight throws CancellationError without waiting for the reply")
    func cancelledInFlight() async throws {
        let stub = StubHTTPTransport()
        stub.holdReplies()
        let repository = makeRepository(stub: stub)

        let call = Task { try await repository.collections() }
        await untilSettled { stub.heldReplyCount == 1 }
        call.cancel()

        await #expect(throws: CancellationError.self) { try await call.value }
        stub.releaseReplies()
    }
}
