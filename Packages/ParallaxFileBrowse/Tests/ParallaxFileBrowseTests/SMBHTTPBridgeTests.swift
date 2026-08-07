import Foundation
import Testing
import ParallaxCore
@testable import ParallaxFileBrowse

@Suite("SMBHTTPBridge", .timeLimit(.minutes(1)))
struct SMBHTTPBridgeTests {

    /// `byte[i] == i % 251`, so any slice is verifiable by index alone.
    private static func fixture(_ count: Int) -> Data {
        Data((0..<count).map { UInt8($0 % 251) })
    }

    /// One 1 MiB body — comfortably inside a single `chunkSize` slice.
    private static let smallSize = 1_048_576
    /// Strictly larger than one chunk, so a full-body fetch walks the streamBody loop several
    /// times. Derived from the production ceiling: widening `chunkSize` must not silently stop
    /// exercising the multi-chunk path.
    private static let multiChunkSize = SMBHTTPBridge.chunkSize * 5 / 2

    /// Runs `body` against a started bridge and always stops it. Swift has no async `defer`, and the
    /// fire-and-forget `Task { await bridge.stop() }` this replaces let listeners outlive their test.
    private func withBridge(
        size: Int = SMBHTTPBridgeTests.smallSize,
        _ body: (SMBHTTPBridge, URL, Data) async throws -> Void
    ) async throws {
        let data = Self.fixture(size)
        let bridge = SMBHTTPBridge(reader: InMemoryRandomAccessReader(data: data),
                                   fileName: "video.mp4", contentType: "video/mp4")
        let url: URL
        do {
            // Loopback, never the default `.lan` scope: headless CI runners grant no local-network
            // access, so LAN-scope self-connections crawl through the policy path for minutes and
            // starve the whole cooperative pool. Loopback is exempt from that path.
            url = try await bridge.start(scope: .loopback)
        } catch {
            await bridge.stop()
            throw error
        }
        do {
            try await body(bridge, url, data)
        } catch {
            await bridge.stop()
            throw error
        }
        await bridge.stop()
    }

    // MARK: - Whole-body and range serving

    @Test("GET with no Range → 200 full body + streaming headers")
    func fullBodyRoundTrip() async throws {
        try await withBridge { _, url, data in
            let (body, response) = try await ephemeralHTTPSession().data(from: url)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 200)
            #expect(http.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
            #expect(http.value(forHTTPHeaderField: "Content-Type") == "video/mp4")
            #expect(http.value(forHTTPHeaderField: "Content-Length") == "\(data.count)")
            #expect(body == data)
        }
    }

    @Test("Range: bytes=1000-2999 → 206 with exact bytes + Content-Range")
    func rangeRequestReturns206WithExactBytes() async throws {
        try await withBridge { _, url, data in
            var request = URLRequest(url: url)
            request.setValue("bytes=1000-2999", forHTTPHeaderField: "Range")
            let (body, response) = try await ephemeralHTTPSession().data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 206)
            #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes 1000-2999/\(data.count)")
            #expect(body == data.subdata(in: 1000..<3000))
        }
    }

    @Test("Open-ended Range serves from the offset to EOF, 206")
    func openEndedRangeServesToEOF() async throws {
        try await withBridge { _, url, data in
            let start = data.count - 576
            var request = URLRequest(url: url)
            request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range")
            let (body, response) = try await ephemeralHTTPSession().data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 206)
            #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes \(start)-\(data.count - 1)/\(data.count)")
            #expect(body == data.subdata(in: start..<data.count))
        }
    }

    @Test("A Range past EOF → 416 with Content-Range */size")
    func unsatisfiableRangeIs416() async throws {
        try await withBridge { _, url, data in
            var request = URLRequest(url: url)
            request.setValue("bytes=\(data.count)-", forHTTPHeaderField: "Range")
            let (_, response) = try await ephemeralHTTPSession().data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 416)
            #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes */\(data.count)")
        }
    }

    /// RFC 7233: a Range the server can't interpret is IGNORED and the full representation served —
    /// not rejected. Suffix ranges (`bytes=-500`) are the real-world shape of this; the rest are
    /// defensive.
    @Test("An uninterpretable Range is ignored and the full body served with 200",
          arguments: ["-500", "abc-def", "100-abc", "3000-2000", ""])
    func uninterpretableRangeServesFullBody(_ spec: String) async throws {
        try await withBridge { _, url, data in
            var request = URLRequest(url: url)
            request.setValue("bytes=\(spec)", forHTTPHeaderField: "Range")
            let (body, response) = try await ephemeralHTTPSession().data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 200)
            #expect(http.value(forHTTPHeaderField: "Content-Length") == "\(data.count)")
            #expect(body == data)
        }
    }

    @Test("Full-body GET over a multi-chunk file byte-equals the fixture")
    func multiChunkFullBodyStreamsExactBytes() async throws {
        try await withBridge(size: Self.multiChunkSize) { _, url, data in
            let (body, response) = try await ephemeralHTTPSession().data(from: url)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 200)
            #expect(http.value(forHTTPHeaderField: "Content-Length") == "\(data.count)")
            #expect(body == data)
        }
    }

    @Test("Range spanning a chunk boundary → 206 with exact bytes")
    func multiChunkRangeSpanningBoundaryReturnsExactBytes() async throws {
        try await withBridge(size: Self.multiChunkSize) { _, url, data in
            // Straddles the ceiling by design: one chunk cannot serve it, so streamBody must
            // iterate. Anchored to the production chunk size rather than a literal byte count.
            let start = SMBHTTPBridge.chunkSize / 2
            let end = start + SMBHTTPBridge.chunkSize + 7
            var request = URLRequest(url: url)
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            let (body, response) = try await ephemeralHTTPSession().data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 206)
            #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes \(start)-\(end)/\(data.count)")
            #expect(body == data.subdata(in: start..<(end + 1)))
        }
    }

    // MARK: - Method and path handling

    @Test("HEAD → 200 with Content-Length and empty body")
    func headRequestReturnsHeadersOnlyNoBody() async throws {
        try await withBridge { _, url, data in
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            let (body, response) = try await ephemeralHTTPSession().data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 200)
            #expect(http.value(forHTTPHeaderField: "Content-Length") == "\(data.count)")
            #expect(body.isEmpty)
        }
    }

    @Test("HEAD with a Range → 206 headers, still no body")
    func headWithRangeReturnsNoBody() async throws {
        try await withBridge { bridge, url, _ in
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
            let (body, response) = try await ephemeralHTTPSession().data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 206)
            #expect(body.isEmpty)
            let stats = await bridge.stats
            #expect(stats.bytesRead == 0, "a HEAD must never pull bytes off the share")
        }
    }

    @Test("POST to the valid URL → 405 Method Not Allowed")
    func postIsMethodNotAllowed() async throws {
        try await withBridge { _, url, _ in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            let (_, response) = try await ephemeralHTTPSession().data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 405)
        }
    }

    @Test("Wrong path token → 404")
    func wrongTokenIs404() async throws {
        try await withBridge { _, url, _ in
            var components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            components.path = "/deadbeefdeadbeefdeadbeefdeadbeef/video.mp4"
            let badURL = try #require(components.url)
            let (_, response) = try await ephemeralHTTPSession().data(from: badURL)
            #expect((response as? HTTPURLResponse)?.statusCode == 404)
        }
    }

    @Test("A query string is stripped before the path is matched")
    func queryStringIsIgnored() async throws {
        try await withBridge { _, url, data in
            var components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            components.query = "cachebust=1"
            let (body, response) = try await ephemeralHTTPSession().data(from: try #require(components.url))
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(body == data)
        }
    }

    // MARK: - Connection lifecycle

    @Test("Two sequential range requests on one connection both return correct bytes")
    func keepAliveSequentialRequestsBothSucceed() async throws {
        try await withBridge { bridge, url, data in
            // One session, so HTTP/1.1 keep-alive reuses the socket and `serve` loops past its
            // first iteration; the accepted-connection count is what makes that observable.
            let session = ephemeralHTTPSession()

            var first = URLRequest(url: url)
            first.setValue("bytes=0-999", forHTTPHeaderField: "Range")
            let (firstBody, firstResponse) = try await session.data(for: first)
            #expect((firstResponse as? HTTPURLResponse)?.statusCode == 206)
            #expect(firstBody == data.subdata(in: 0..<1000))

            var second = URLRequest(url: url)
            second.setValue("bytes=1000-1999", forHTTPHeaderField: "Range")
            let (secondBody, secondResponse) = try await session.data(for: second)
            #expect((secondResponse as? HTTPURLResponse)?.statusCode == 206)
            #expect(secondBody == data.subdata(in: 1000..<2000))

            let stats = await bridge.stats
            #expect(stats.bytesRead == 2000)
        }
    }

    @Test("stats count bytes pulled from the reader and accepted connections")
    func statsCountReaderBytesAndConnections() async throws {
        try await withBridge { bridge, url, _ in
            var request = URLRequest(url: url)
            request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
            let (body, _) = try await ephemeralHTTPSession().data(for: request)
            #expect(body.count == 4096)

            let stats = await bridge.stats
            #expect(stats.bytesRead == 4096)
            #expect(stats.connections == 1)
        }
    }

    @Test("stop() refuses new connections")
    func stopRefusesNewConnections() async throws {
        let data = Self.fixture(1024)
        let bridge = SMBHTTPBridge(reader: InMemoryRandomAccessReader(data: data),
                                   fileName: "video.mp4", contentType: "video/mp4")
        let url = try await bridge.start()
        await bridge.stop()

        let error = await #expect(throws: URLError.self) {
            _ = try await ephemeralHTTPSession(timeout: 3).data(from: url)
        }
        // A closed port refuses immediately; a timeout would mean the listener was still accepting.
        #expect(error?.code != .timedOut, "a stopped bridge must refuse the connection, not hang")
    }

    @Test("start() is single-shot, and a stopped bridge can never be restarted")
    func startIsSingleShotAndStopIsPermanent() async throws {
        let bridge = SMBHTTPBridge(reader: InMemoryRandomAccessReader(data: Self.fixture(16)),
                                   fileName: "video.mp4", contentType: "video/mp4")
        _ = try await bridge.start()

        await #expect(throws: SMBHTTPBridge.BridgeError.alreadyStarted) { _ = try await bridge.start() }

        await bridge.stop()
        await bridge.stop()   // idempotent

        await #expect(throws: SMBHTTPBridge.BridgeError.stopped) { _ = try await bridge.start() }
    }

    // MARK: - Malformed request heads
    //
    // URLSession will not emit any of these, so they go out over a raw socket. Each must close the
    // connection without a response rather than answering or hanging.

    @Test("A malformed request line closes the connection with no response")
    func malformedRequestLineClosesSilently() async throws {
        try await withBridge { _, url, _ in
            let response = try await rawHTTPExchange(with: url, sending: Data("HELLO\r\n\r\n".utf8))
            #expect(response.isEmpty)
        }
    }

    @Test("EOF before the head terminator closes the connection with no response")
    func truncatedHeadClosesSilently() async throws {
        try await withBridge { _, url, _ in
            let partial = Data("GET \(url.path) HTTP/1.1\r\nHost: x\r\n".utf8)
            let response = try await rawHTTPExchange(with: url, sending: partial, halfCloseAfterSend: true)
            #expect(response.isEmpty)
        }
    }

    @Test("A head past the size cap is rejected without a response")
    func oversizedHeadIsRejected() async throws {
        try await withBridge { _, url, _ in
            // Never terminated, and larger than the cap, so the reader gives up on it.
            var head = Data("GET \(url.path) HTTP/1.1\r\n".utf8)
            head.append(Data("X-Filler: \(String(repeating: "a", count: SMBHTTPBridge.maxHeadBytes))\r\n".utf8))
            let response = try await rawHTTPExchange(with: url, sending: head)
            #expect(response.isEmpty)
        }
    }

    @Test("Connection: close is honored — the response is served, then the socket closes")
    func connectionCloseIsHonored() async throws {
        try await withBridge { _, url, data in
            let head = Data("GET \(url.path) HTTP/1.1\r\nHost: x\r\nRange: bytes=0-9\r\nConnection: close\r\n\r\n".utf8)
            let response = try await rawHTTPExchange(with: url, sending: head)
            let text = String(decoding: response, as: UTF8.self)
            #expect(text.hasPrefix("HTTP/1.1 206 Partial Content"))
            #expect(text.contains("Connection: close"))
            #expect(response.suffix(10) == data.subdata(in: 0..<10))
        }
    }

    @Test("An HTTP/1.0 request defaults to close and still gets its body")
    func http10DefaultsToClose() async throws {
        try await withBridge { _, url, data in
            let head = Data("GET \(url.path) HTTP/1.0\r\nHost: x\r\nRange: bytes=0-9\r\n\r\n".utf8)
            let response = try await rawHTTPExchange(with: url, sending: head)
            let text = String(decoding: response, as: UTF8.self)
            #expect(text.hasPrefix("HTTP/1.1 206 Partial Content"))
            #expect(text.contains("Connection: close"))
            #expect(response.suffix(10) == data.subdata(in: 0..<10))
        }
    }
}
