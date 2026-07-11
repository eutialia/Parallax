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

    /// 5 MiB of deterministic bytes (strictly larger than one 2 MiB `chunkSize` slice), so a
    /// full-body fetch exercises the streamBody offset-advance/remaining-decrement loop across
    /// at least 3 iterations (5 MiB / 2 MiB chunks).
    private func makeLargeBridge() -> (SMBHTTPBridge, Data) {
        let data = Data((0..<5_242_880).map { UInt8($0 % 251) })
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

    @Test("Full-body GET over a multi-chunk file byte-equals the fixture")
    func multiChunkFullBodyStreamsExactBytes() async throws {
        let (bridge, data) = makeLargeBridge()
        let url = try await bridge.start()
        defer { Task { await bridge.stop() } }
        let (body, response) = try await URLSession.shared.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Length") == "5242880")
        #expect(body == data)
    }

    @Test("Range spanning a chunk boundary → 206 with exact bytes")
    func multiChunkRangeSpanningBoundaryReturnsExactBytes() async throws {
        let (bridge, data) = makeLargeBridge()
        let url = try await bridge.start()
        defer { Task { await bridge.stop() } }
        // 1_000_000-4_200_000 is ~3.05 MiB, wider than the 2 MiB chunkSize, so streamBody must
        // issue at least 2 reader.read/send iterations to serve it.
        var req = URLRequest(url: url)
        req.setValue("bytes=1000000-4200000", forHTTPHeaderField: "Range")
        let (body, response) = try await URLSession.shared.data(for: req)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 206)
        #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes 1000000-4200000/5242880")
        #expect(body == data.subdata(in: 1_000_000..<4_200_001))
    }

    @Test("HEAD → 200 with Content-Length and empty body")
    func headRequestReturnsHeadersOnlyNoBody() async throws {
        let (bridge, data) = makeBridge()
        let url = try await bridge.start()
        defer { Task { await bridge.stop() } }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        let (body, response) = try await URLSession.shared.data(for: req)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Length") == "\(data.count)")
        #expect(body.isEmpty)
    }

    @Test("POST to the valid URL → 405 Method Not Allowed")
    func postIsMethodNotAllowed() async throws {
        let (bridge, _) = makeBridge()
        let url = try await bridge.start()
        defer { Task { await bridge.stop() } }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: req)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 405)
    }

    // Two sequential range requests over the shared default `URLSession` (which pools/reuses
    // HTTP/1.1 connections by host+port): a second request landing on the same TCP connection
    // exercises `serve(_:)`'s keep-alive loop past its first iteration. This is best-effort
    // observability, not a guarantee URLSession reused the socket — no sleeps, no introspection
    // of the actual connection identity, just correctness of both responses.
    @Test("Two sequential range requests over one URLSession both return correct bytes")
    func keepAliveSequentialRequestsBothSucceed() async throws {
        let (bridge, data) = makeBridge()
        let url = try await bridge.start()
        defer { Task { await bridge.stop() } }

        var first = URLRequest(url: url)
        first.setValue("bytes=0-999", forHTTPHeaderField: "Range")
        let (firstBody, firstResponse) = try await URLSession.shared.data(for: first)
        let firstHTTP = try #require(firstResponse as? HTTPURLResponse)
        #expect(firstHTTP.statusCode == 206)
        #expect(firstBody == data.subdata(in: 0..<1000))

        var second = URLRequest(url: url)
        second.setValue("bytes=1000-1999", forHTTPHeaderField: "Range")
        let (secondBody, secondResponse) = try await URLSession.shared.data(for: second)
        let secondHTTP = try #require(secondResponse as? HTTPURLResponse)
        #expect(secondHTTP.statusCode == 206)
        #expect(secondBody == data.subdata(in: 1000..<2000))
    }

    @Test("stats count bytes pulled from the reader and accepted connections")
    func statsCountReaderBytesAndConnections() async throws {
        let (bridge, _) = makeBridge()
        let url = try await bridge.start()
        defer { Task { await bridge.stop() } }

        var req = URLRequest(url: url)
        req.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        let (body, _) = try await URLSession.shared.data(for: req)
        #expect(body.count == 4096)

        let stats = await bridge.stats
        #expect(stats.bytesRead == 4096)
        #expect(stats.connections == 1)
    }
}
