import Foundation
import Testing
import ParallaxCore
@testable import ParallaxFileBrowse

@Suite("SMBHTTPBridge")
struct SMBHTTPBridgeTests {

    /// 1 MiB of deterministic bytes, `byte[i] == i % 251`.
    private func makeBridge() -> (SMBHTTPBridge, Data) {
        let data = Data((0..<1_048_576).map { UInt8($0 % 251) })
        return (SMBHTTPBridge(reader: InMemoryRandomAccessReader(data: data),
                              fileName: "video.mp4", contentType: "video/mp4"), data)
    }

    @Test("GET with no Range → 200 full body + streaming headers")
    func fullBodyRoundTrip() async throws {
        let (bridge, data) = makeBridge()
        let url = try await bridge.start()
        defer { Task { await bridge.stop() } }
        let (body, response) = try await URLSession.shared.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "video/mp4")
        #expect(body == data)
    }

    @Test("Range: bytes=1000-2999 → 206 with exact bytes + Content-Range")
    func rangeRequestReturns206WithExactBytes() async throws {
        let (bridge, data) = makeBridge()
        let url = try await bridge.start()
        defer { Task { await bridge.stop() } }
        var req = URLRequest(url: url)
        req.setValue("bytes=1000-2999", forHTTPHeaderField: "Range")
        let (body, response) = try await URLSession.shared.data(for: req)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 206)
        #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes 1000-2999/1048576")
        #expect(body == data.subdata(in: 1000..<3000))
    }

    @Test("Open-ended Range: bytes=1048000- → 576 bytes to EOF, 206")
    func openEndedRangeServesToEOF() async throws {
        let (bridge, data) = makeBridge()
        let url = try await bridge.start()
        defer { Task { await bridge.stop() } }
        var req = URLRequest(url: url)
        req.setValue("bytes=1048000-", forHTTPHeaderField: "Range")
        let (body, response) = try await URLSession.shared.data(for: req)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 206)
        #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes 1048000-1048575/1048576")
        #expect(body == data.subdata(in: 1048000..<1_048_576))
        #expect(body.count == 576)
    }

    @Test("Unsatisfiable Range: bytes=2000000- → 416 with Content-Range */size")
    func unsatisfiableRangeIs416() async throws {
        let (bridge, _) = makeBridge()
        let url = try await bridge.start()
        defer { Task { await bridge.stop() } }
        var req = URLRequest(url: url)
        req.setValue("bytes=2000000-", forHTTPHeaderField: "Range")
        let (_, response) = try await URLSession.shared.data(for: req)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 416)
        #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes */1048576")
    }

    @Test("Wrong path token → 404")
    func wrongTokenIs404() async throws {
        let (bridge, _) = makeBridge()
        let url = try await bridge.start()
        defer { Task { await bridge.stop() } }
        // Swap the token segment for a bogus one, keep host/port/fileName.
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.path = "/deadbeefdeadbeefdeadbeefdeadbeef/video.mp4"
        let badURL = try #require(components.url)
        let (_, response) = try await URLSession.shared.data(from: badURL)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 404)
    }

    @Test("stop() refuses new connections")
    func stopRefusesNewConnections() async throws {
        let (bridge, _) = makeBridge()
        let url = try await bridge.start()
        await bridge.stop()
        // A short-timeout session so a refused/dead port fails fast rather than hanging.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3
        let session = URLSession(configuration: config)
        await #expect(throws: (any Error).self) {
            _ = try await session.data(from: url)
        }
    }
}
