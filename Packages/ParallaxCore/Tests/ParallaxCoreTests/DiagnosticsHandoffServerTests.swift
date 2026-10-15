import Foundation
import ParallaxCoreTestSupport
import ParallaxTestScaling
import Testing
@testable import ParallaxCore

@Suite("Diagnostics handoff server", .scaledTimeLimit())
struct DiagnosticsHandoffServerTests {

    /// Large enough that a client which never reads parks the server's send against a full socket
    /// buffer.
    private static let stalledPayload = Data(count: 16 << 20)

    @Test("A server whose clients reset mid-download is freed once it stops")
    func resetClientsDoNotPinTheServer() async throws {
        let freed = WeakServer()
        try await {
            let server = DiagnosticsHandoffServer(payload: Self.stalledPayload, fileName: "log.txt")
            freed.server = server
            let url = try await Self.loopbackURL(of: server)
            let downloads = try (0..<4).map { _ in try StalledDownload(url: url) }
            await untilSettled { await server.liveConnectionCount == 4 }
            // Only a lower bound on "parked in send": a reset that lands while the serve is still
            // reading the head unwinds on its own and would pass without the fix.
            try await Task.sleep(for: CITimeScale.seconds(0.3))

            downloads.prefix(2).forEach { $0.reset() }
            await untilSettled { await server.liveConnectionCount == 2 }
            await server.stop()
            downloads.dropFirst(2).forEach { $0.close() }
        }()
        await untilSettled { freed.server == nil }
    }

    @Test("A listener that dies after it was ready stops the server")
    func listenerFailureStopsTheServer() async throws {
        let server = DiagnosticsHandoffServer(payload: Data("PAYLOAD".utf8), fileName: "log.txt")
        _ = try await server.start()
        let listener = try #require(await server.listener)

        listener.cancel()

        await server.waitUntilStopped()
        #expect(await server.listener == nil)
    }

    /// The listener binds every interface; the test reaches it over loopback, which headless CI
    /// runners are allowed to talk to without local-network access.
    private static func loopbackURL(of server: DiagnosticsHandoffServer) async throws -> URL {
        let endpoint = try await server.start()
        let port = try #require(endpoint.url.port)
        return try #require(URL(string: "http://127.0.0.1:\(port)\(endpoint.url.path)"))
    }
}

private final class WeakServer: @unchecked Sendable {
    weak var server: DiagnosticsHandoffServer?
}
