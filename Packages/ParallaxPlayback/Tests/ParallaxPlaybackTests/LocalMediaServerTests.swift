import Foundation
import Synchronization
import Testing
import ParallaxTestScaling
import ParallaxCore
import ParallaxCoreTestSupport
@testable import ParallaxPlayback

/// `.serialized` caps what this suite costs at any one instant: run in parallel it stands up ~21
/// listeners and sockets at once, plus the two multi-chunk fixtures, which a 2-core CI runner
/// cannot absorb. One bridge at a time still exercises every path — nothing here tests concurrency.
@Suite("LocalMediaServer", .serialized, .scaledTimeLimit(minutes: 3))
struct LocalMediaServerTests {

    /// `byte[i] == i % 251`, so any slice is verifiable by index alone. Filled in place: the
    /// `map`-into-`Data` this replaces built a whole intermediate array first, which at
    /// `multiChunkSize` is megabytes of pointless churn in an unoptimised test build.
    private static func fixture(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for i in 0..<count { raw[i] = UInt8(i % 251) }
        }
        return data
    }

    /// Default body: big enough for every slice these tests ask for (the largest is `bytes=0-4095`)
    /// and nothing more. Byte-exactness over a repeating pattern proves no more at 1 MiB than at
    /// 8 KiB, and the `streamBody` chunk loop is the multi-chunk tests' job, not this size's.
    private static let smallSize = 8 * 1024
    /// Strictly larger than one chunk, so a full-body fetch walks the streamBody loop several
    /// times. Derived from the production ceiling: widening `chunkSize` must not silently stop
    /// exercising the multi-chunk path.
    private static let multiChunkSize = LocalMediaServer.chunkSize * 5 / 2
    /// Must outrun what loopback socket buffers absorb, or the bridge finishes sending and idles in
    /// `receive` instead of parking a `send`. Measured against the unfixed handler: 512 KiB passes
    /// (no stall), 1,000,000 bytes fails. Two ceiling chunks leaves a wide margin over that edge.
    private static let stalledSize = LocalMediaServer.chunkSize * 2

    /// Runs `body` against a started bridge and always stops it. Swift has no async `defer`, and the
    /// fire-and-forget `Task { await bridge.stop() }` this replaces let listeners outlive their test.
    private func withBridge(
        size: Int = LocalMediaServerTests.smallSize,
        _ body: (LocalMediaServer, URL, Data) async throws -> Void
    ) async throws {
        let data = Self.fixture(size)
        let bridge = LocalMediaServer(responder: FileRangeResponder(
            reader: InMemoryRandomAccessReader(data: data), fileName: "video.mp4", contentType: "video/mp4"))
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
            let start = LocalMediaServer.chunkSize / 2
            let end = start + LocalMediaServer.chunkSize + 7
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

    private struct Unreadable: Error {}

    /// Two resources and one path whose lookup fails.
    private struct Catalog: MediaResponder {
        let entryPath = "first.bin"

        func resource(at path: String) async throws -> ServedResource? {
            switch path {
            case "first.bin": ServedResource(Data("first".utf8), contentType: "application/x-first")
            case "nested/second.bin": ServedResource(Data("second".utf8), contentType: "application/x-second")
            case "broken.bin": throw Unreadable()
            default: nil
            }
        }

        func role(of path: String) -> String? {
            ["first.bin", "nested/second.bin", "broken.bin"].contains(path) ? path : nil
        }
    }

    @Test("Each path under the token gets its responder's answer: bytes with their type, 404 for none, 500 for a failed lookup")
    func pathsAreAnsweredByTheResponder() async throws {
        let server = LocalMediaServer(responder: Catalog())
        let entry = try await server.start(scope: .loopback)
        let session = ephemeralHTTPSession()
        var answers: [String] = []
        for path in ["first.bin", "nested/second.bin", "missing.bin", "broken.bin", "first.bin"] {
            let (body, response) = try await session.data(from: entry.deletingLastPathComponent().appending(path: path))
            let http = try #require(response as? HTTPURLResponse)
            answers.append("\(http.statusCode) \(http.value(forHTTPHeaderField: "Content-Type") ?? "-") \(String(decoding: body, as: UTF8.self))")
        }
        await untilSettled { await server.records.count == 5 }
        let records = await server.records
        await server.stop()

        #expect(answers == [
            "200 application/x-first first",
            "200 application/x-second second",
            "404 - ",
            "500 - ",
            "200 application/x-first first",
        ])
        // A path that names nothing is logged as unknown, never by its name.
        #expect(records.map { "\($0.resource) \($0.status)" } == [
            "first.bin 200", "nested/second.bin 200", "unknown 404", "broken.bin 500", "first.bin 200",
        ])
        #expect(records[3].ending == .failed(afterBytes: 0, by: Unreadable()))
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

            await untilSettled { await bridge.records.count == 1 }
            let record = try #require(await bridge.records.first)
            #expect(record.resource == "file" && record.status == 206 && record.ending == .complete)
            #expect(record.bytesSent == 4096 && record.bytesFetched == 4096 && record.firstByte != nil)
        }
    }

    @Test("stop() refuses new connections")
    func stopRefusesNewConnections() async throws {
        let data = Self.fixture(1024)
        let bridge = LocalMediaServer(responder: FileRangeResponder(
            reader: InMemoryRandomAccessReader(data: data), fileName: "video.mp4", contentType: "video/mp4"))
        let url = try await bridge.start(scope: .loopback)
        await bridge.stop()

        let error = await #expect(throws: URLError.self) {
            _ = try await ephemeralHTTPSession(timeout: 3).data(from: url)
        }
        // A closed port refuses immediately; a timeout would mean the listener was still accepting.
        #expect(error?.code != .timedOut, "a stopped bridge must refuse the connection, not hang")
    }

    @Test("start() is single-shot, and a stopped bridge can never be restarted")
    func startIsSingleShotAndStopIsPermanent() async throws {
        let bridge = LocalMediaServer(responder: FileRangeResponder(
            reader: InMemoryRandomAccessReader(data: Self.fixture(16)), fileName: "video.mp4", contentType: "video/mp4"))
        _ = try await bridge.start(scope: .loopback)

        await #expect(throws: LocalMediaServer.ServerError.alreadyStarted) { _ = try await bridge.start(scope: .loopback) }

        await bridge.stop()
        await bridge.stop()   // idempotent

        await #expect(throws: LocalMediaServer.ServerError.stopped) { _ = try await bridge.start(scope: .loopback) }
    }

    @Test("A bridge whose clients reset mid-download is freed once it stops")
    func resetClientsDoNotPinTheBridge() async throws {
        let freed = WeakBridge()
        try await withBridge(size: Self.stalledSize) { bridge, url, _ in
            freed.bridge = bridge
            let downloads = try (0..<4).map { _ in try StalledDownload(url: url) }
            await untilSettled { await bridge.liveConnectionCount == 4 }
            let parked = QuietPoll()
            await untilSettled {
                try? await Task.sleep(for: .milliseconds(20))
                return await parked.isQuiet(afterReading: bridge.stats.bytesRead)
            }

            downloads.prefix(2).forEach { $0.reset() }
            await untilSettled { await bridge.liveConnectionCount == 2 }
            await bridge.stop()
            downloads.dropFirst(2).forEach { $0.close() }
        }
        await untilSettled { freed.bridge == nil }
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
            head.append(Data("X-Filler: \(String(repeating: "a", count: LocalMediaServer.maxHeadBytes))\r\n".utf8))
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

    // MARK: - Streamed bodies

    /// Hands out its pieces, then ends, fails, or waits until it is cancelled.
    private final class ScriptedProducer: BodyProducer {
        enum Then: Sendable { case end, fail, wait }

        private let pieces: [Data]
        private let then: Then
        private let state = Mutex<(next: Int, cancelled: Bool, waiter: CheckedContinuation<Void, Never>?)>((0, false, nil))

        init(_ pieces: [String], then: Then) {
            self.pieces = pieces.map { Data($0.utf8) }
            self.then = then
        }

        var wasCancelled: Bool { state.withLock { $0.cancelled } }

        /// The pieces handed out, as if each were read from a file.
        var bytesFetched: Int {
            pieces.prefix(state.withLock { $0.next }).reduce(0) { $0 + $1.count }
        }

        func next() async throws -> Data? {
            let index = state.withLock { state in
                defer { state.next += 1 }
                return state.next
            }
            if index < pieces.count { return pieces[index] }
            switch then {
            case .end: return nil
            case .fail: throw Unreadable()
            case .wait:
                await withCheckedContinuation { continuation in
                    let cancelled = state.withLock { state in
                        if !state.cancelled { state.waiter = continuation }
                        return state.cancelled
                    }
                    if cancelled { continuation.resume() }
                }
                throw CancellationError()
            }
        }

        func cancel() {
            let waiter = state.withLock { state in
                state.cancelled = true
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume()
        }
    }

    /// One streamed path, whose producers it keeps.
    private final class Streaming: MediaResponder {
        let entryPath = "segment.m4s"
        private let pieces: [String]
        private let then: ScriptedProducer.Then
        private let made = Mutex<[ScriptedProducer]>([])

        init(_ pieces: [String], then: ScriptedProducer.Then) {
            self.pieces = pieces
            self.then = then
        }

        var producers: [ScriptedProducer] { made.withLock { $0 } }

        func role(of path: String) -> String? {
            path == entryPath ? path : nil
        }

        func resource(at path: String) async throws -> ServedResource? {
            guard path == entryPath else { return nil }
            return ServedResource(contentType: "video/mp4") {
                let producer = ScriptedProducer(self.pieces, then: self.then)
                self.made.withLock { $0.append(producer) }
                return producer
            }
        }
    }

    /// The server's records once every connection has closed. Its clock never moves, so each
    /// record's times are zero.
    @discardableResult
    private func withServer(_ responder: Streaming, _ body: (URL) async throws -> Void) async throws -> [RequestRecord] {
        let server = LocalMediaServer(responder: responder, clock: TestClock())
        let url = try await server.start(scope: .loopback)
        do {
            try await body(url)
        } catch {
            await server.stop()
            throw error
        }
        await untilSettled { await server.liveConnectionCount == 0 }
        let records = await server.records
        await server.stop()
        return records
    }

    private static func record(
        _ status: Int, sent: Int, firstByte: Duration? = .zero, _ ending: RequestRecord.Ending = .complete
    ) -> RequestRecord {
        RequestRecord(
            resource: "segment.m4s", status: status, firstByte: firstByte, duration: .zero, bytesSent: sent,
            bytesFetched: sent, ending: ending)
    }

    private static func request(_ url: URL, _ fields: String = "", method: String = "GET") -> String {
        "\(method) \(url.path) HTTP/1.1\r\nHost: x\r\n\(fields)\r\n"
    }

    @Test("a streamed body goes out as one chunk per piece, with no length and no ranges, whatever Range asks")
    func streamedBodyIsChunked() async throws {
        let responder = Streaming(["first", "second piece"], then: .end)
        let records = try await withServer(responder) { url in
            let head = Self.request(url, "Range: bytes=3-9\r\nConnection: close\r\n")
            let response = String(decoding: try await rawHTTPExchange(with: url, sending: Data(head.utf8)), as: UTF8.self)
            let (headers, body) = try #require(response.split(separator: "\r\n\r\n", maxSplits: 1).map(String.init).pair)

            #expect(headers.hasPrefix("HTTP/1.1 200 OK"))
            #expect(headers.contains("Transfer-Encoding: chunked"))
            #expect(!headers.contains("Content-Length") && !headers.contains("Accept-Ranges"))
            #expect(body == "5\r\nfirst\r\nc\r\nsecond piece\r\n0\r\n\r\n")
        }
        #expect(records == [Self.record(200, sent: 17)])
    }

    @Test("HEAD of a streamed resource answers its headers and starts nothing")
    func headOfStreamedResourceStartsNothing() async throws {
        let responder = Streaming(["first"], then: .end)
        let records = try await withServer(responder) { url in
            let head = Self.request(url, "Connection: close\r\n", method: "HEAD")
            let response = String(decoding: try await rawHTTPExchange(with: url, sending: Data(head.utf8)), as: UTF8.self)

            #expect(response.hasPrefix("HTTP/1.1 200 OK"))
            #expect(response.hasSuffix("\r\n\r\n"))
            #expect(responder.producers.isEmpty)
        }
        #expect(records == [Self.record(200, sent: 0, firstByte: nil)])
    }

    @Test("a streamed body that fails before its first piece is a 500, and the connection serves on")
    func streamFailingBeforeItsFirstPieceIs500() async throws {
        let responder = Streaming([], then: .fail)
        let records = try await withServer(responder) { url in
            let heads = Self.request(url) + Self.request(url, "Connection: close\r\n")
            let response = String(decoding: try await rawHTTPExchange(with: url, sending: Data(heads.utf8)), as: UTF8.self)

            #expect(response.components(separatedBy: "HTTP/1.1 500 Internal Server Error").count == 3, "\(response)")
        }
        let failed = Self.record(500, sent: 0, firstByte: nil, .failed(afterBytes: 0, by: Unreadable()))
        #expect(records == [failed, failed])
    }

    @Test("a streamed body that fails after its first piece closes the connection without the last chunk")
    func streamFailingLaterClosesWithoutTheLastChunk() async throws {
        let responder = Streaming(["first"], then: .fail)
        let records = try await withServer(responder) { url in
            let started = ContinuousClock.now
            let response = String(
                decoding: try await rawHTTPExchange(with: url, sending: Data(Self.request(url).utf8), timeout: .seconds(4)),
                as: UTF8.self)

            #expect(response.hasSuffix("5\r\nfirst\r\n"), "\(response)")
            // Closed by the server, not by the exchange's deadline.
            #expect(ContinuousClock.now - started < CITimeScale.seconds(3))
        }
        #expect(records == [Self.record(200, sent: 5, .failed(afterBytes: 5, by: Unreadable()))])
    }

    @Test("a client that drops a streamed response stops its producer")
    func droppedClientCancelsTheProducer() async throws {
        let responder = Streaming(["first"], then: .wait)
        let records = try await withServer(responder) { url in
            // The exchange gives up after its timeout and cancels its connection mid-body.
            let response = try await rawHTTPExchange(
                with: url, sending: Data(Self.request(url).utf8), timeout: .milliseconds(300))
            #expect(String(decoding: response, as: UTF8.self).hasSuffix("5\r\nfirst\r\n"))

            await untilSettled { responder.producers.first?.wasCancelled == true }
            #expect(responder.producers.map(\.wasCancelled) == [true])
        }
        #expect(records == [Self.record(200, sent: 5, .dropped)])
    }

    @Test("a request sent behind a streamed one on the same connection is answered after it")
    func pipelinedRequestIsAnsweredAfterTheStream() async throws {
        let responder = Streaming(["first"], then: .end)
        let records = try await withServer(responder) { url in
            let heads = Self.request(url) + Self.request(url, "Connection: close\r\n")
            let response = String(decoding: try await rawHTTPExchange(with: url, sending: Data(heads.utf8)), as: UTF8.self)

            #expect(response.components(separatedBy: "5\r\nfirst\r\n0\r\n\r\n").count == 3, "\(response)")
            #expect(responder.producers.count == 2)
        }
        #expect(records == [Self.record(200, sent: 5), Self.record(200, sent: 5)])
    }
}

private final class QuietPoll: @unchecked Sendable {
    private var last: UInt64 = 0
    private var stablePolls = 0
    func isQuiet(afterReading bytes: UInt64) -> Bool {
        stablePolls = bytes > 0 && bytes == last ? stablePolls + 1 : 0
        last = bytes
        return stablePolls >= 10
    }
}

private final class WeakBridge: @unchecked Sendable {
    weak var bridge: LocalMediaServer?
}

private extension Array {
    var pair: (Element, Element)? { count == 2 ? (self[0], self[1]) : nil }
}
