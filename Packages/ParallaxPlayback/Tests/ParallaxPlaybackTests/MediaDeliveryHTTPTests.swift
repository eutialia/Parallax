import Foundation
import Synchronization
import Testing
import ParallaxCore
import ParallaxCoreTestSupport
import ParallaxTestScaling
import ParallaxPlayback
import ParallaxPlaybackTestSupport

/// What an HTTP client gets from a delivery's URL and the paths beside it.
///
/// `.serialized` because the stalled-download case holds four 5 MiB responses against full
/// socket buffers, which a 2-core CI runner cannot absorb next to the rest.
@Suite("MediaDelivery — HTTP", .serialized, .scaledTimeLimit(minutes: 3))
struct MediaDeliveryHTTPTests {

    /// High profile H.264 and AAC, served as stored.
    private static let direct = "mp4-h264.mp4"

    /// An MP4 served as stored whose 5 MiB `mdat` is `byte[i] == i % 251`: longer than the
    /// server's largest read of 2 MiB, so a body takes several, and longer than loopback
    /// socket buffers absorb.
    private static let large: Data = {
        let payload = 5 << 20
        var file = ISOBMFFFixtures.mp4(traks: [
            ISOBMFFFixtures.trak(stsdEntries: ["avc1"], handler: "vide"),
            ISOBMFFFixtures.trak(stsdEntries: ["mp4a"], handler: "soun"),
        ], mdatByteCount: payload)
        let start = file.count - payload
        file.withUnsafeMutableBytes { raw in
            for index in 0..<payload { raw[start + index] = UInt8(index % 251) }
        }
        return file
    }()

    /// H.264, AAC and AC-3, bridged. Its open reads 256 KB blocks 0, 2 and 3 of it, so `v-1` and
    /// `v-3` read block 1 from the share, `v-3` before its first fragment.
    private static let bridged = "h264-mkvmerge"
    /// Bridged, with four audio tracks. Its open reads blocks 0, 3 and 5 of it; `a0-0` makes its
    /// first fragment from block 0, then reads blocks 1 and 2 from the share.
    private static let fourTracks = "four-audio-tracks"
    private static let blocksOneAndTwo: Range<UInt64> = 262_144..<786_432

    private static func start(_ reader: any RandomAccessReading, named name: String) async throws -> DeliveredFile {
        try await DeliveredFile.start(reading: reader, named: name, support: .baseline, clock: TestClock())
    }

    /// Runs `body` against a delivery of `bytes` and always stops it.
    private func withDelivery(
        of bytes: Data, named name: String = MediaDeliveryHTTPTests.direct,
        _ body: (DeliveredFile, CountingReader) async throws -> Void
    ) async throws {
        let reader = CountingReader(bytes)
        let file = try await Self.start(reader, named: name)
        do {
            try await body(file, reader)
        } catch {
            await file.stop()
            throw error
        }
        await file.stop()
    }

    private func withDirect(_ body: (URL, Data, CountingReader) async throws -> Void) async throws {
        let data = try BridgeFixture.data(Self.direct)
        try await withDelivery(of: data) { file, reader in try await body(file.delivery.url, data, reader) }
    }

    private static func request(_ url: URL, _ fields: String = "", method: String = "GET") -> String {
        "\(method) \(url.path) HTTP/1.1\r\nHost: x\r\n\(fields)\r\n"
    }

    /// What the server sent on one connection before it closed it. A close by the exchange's
    /// own deadline instead is a failure: the server held a connection it should have let go.
    private static func exchange(
        _ url: URL, _ text: String, halfClosing: Bool = false, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> Data {
        let started = ContinuousClock.now
        let response = try await rawHTTPExchange(
            with: url, sending: Data(text.utf8), halfCloseAfterSend: halfClosing, timeout: .seconds(4))
        #expect(ContinuousClock.now - started < CITimeScale.seconds(3), "the server never closed", sourceLocation: sourceLocation)
        return response
    }

    private static func ranged(_ url: URL, _ spec: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("bytes=\(spec)", forHTTPHeaderField: "Range")
        return request
    }

    // MARK: - A file served as stored

    @Test("GET with no Range → 200 full body + streaming headers")
    func fullBodyRoundTrip() async throws {
        try await withDirect { url, data, _ in
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
        try await withDirect { url, data, _ in
            let (body, response) = try await ephemeralHTTPSession().data(for: Self.ranged(url, "1000-2999"))
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 206)
            #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes 1000-2999/\(data.count)")
            #expect(http.value(forHTTPHeaderField: "Content-Length") == "2000")
            #expect(body == data.subdata(in: 1000..<3000))
        }
    }

    @Test("Open-ended Range serves from the offset to EOF, 206")
    func openEndedRangeServesToEOF() async throws {
        try await withDirect { url, data, _ in
            let start = data.count - 576
            let (body, response) = try await ephemeralHTTPSession().data(for: Self.ranged(url, "\(start)-"))
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 206)
            #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes \(start)-\(data.count - 1)/\(data.count)")
            #expect(body == data.subdata(in: start..<data.count))
        }
    }

    @Test("A Range past EOF → 416 with Content-Range */size")
    func unsatisfiableRangeIs416() async throws {
        try await withDirect { url, data, _ in
            let (_, response) = try await ephemeralHTTPSession().data(for: Self.ranged(url, "\(data.count)-"))
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 416)
            #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes */\(data.count)")
        }
    }

    /// RFC 7233: a Range the server cannot interpret is ignored and the whole file served.
    /// Suffix ranges (`bytes=-500`) are the real-world shape of this; the rest are defensive.
    @Test("An uninterpretable Range is ignored and the full body served with 200",
          arguments: ["-500", "abc-def", "100-abc", "3000-2000", ""])
    func uninterpretableRangeServesFullBody(_ spec: String) async throws {
        try await withDirect { url, data, _ in
            let (body, response) = try await ephemeralHTTPSession().data(for: Self.ranged(url, spec))
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 200)
            #expect(http.value(forHTTPHeaderField: "Content-Length") == "\(data.count)")
            #expect(body == data)
        }
    }

    @Test("Full-body GET over a multi-chunk file byte-equals the fixture")
    func multiChunkFullBodyStreamsExactBytes() async throws {
        try await withDelivery(of: Self.large, named: "large.mp4") { file, _ in
            let (body, response) = try await ephemeralHTTPSession().data(from: file.delivery.url)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 200)
            #expect(http.value(forHTTPHeaderField: "Content-Length") == "\(Self.large.count)")
            #expect(body == Self.large)
        }
    }

    @Test("Range spanning a chunk boundary → 206 with exact bytes")
    func multiChunkRangeSpanningBoundaryReturnsExactBytes() async throws {
        try await withDelivery(of: Self.large, named: "large.mp4") { file, _ in
            // Longer than the server's largest read, so no one read serves it.
            let (start, end) = (1 << 20, (3 << 20) + 7)
            let (body, response) = try await ephemeralHTTPSession().data(for: Self.ranged(file.delivery.url, "\(start)-\(end)"))
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 206)
            #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes \(start)-\(end)/\(Self.large.count)")
            #expect(body == Self.large.subdata(in: start..<(end + 1)))
        }
    }

    @Test("HEAD → 200 with Content-Length and empty body")
    func headRequestReturnsHeadersOnlyNoBody() async throws {
        try await withDirect { url, data, reader in
            let before = reader.requests
            // Raw: URLSession drops whatever follows a HEAD response's head.
            let response = try await Self.exchange(url, Self.request(url, "Connection: close\r\n", method: "HEAD"))
            let head = try #require(WireResponse.all(in: response).first)

            #expect(head.status == 200)
            #expect(head.field("Content-Length") == "\(data.count)")
            #expect(response.range(of: Data("\r\n\r\n".utf8))?.upperBound == response.endIndex)
            #expect(reader.requests == before)
        }
    }

    @Test("HEAD with a Range → 206 headers, still no body, and nothing read from the share")
    func headWithRangeReturnsNoBody() async throws {
        try await withDirect { url, _, reader in
            let before = reader.requests
            let (body, response) = try await ephemeralHTTPSession().data(for: Self.ranged(url, "0-1023", method: "HEAD"))
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 206)
            #expect(body.isEmpty)
            #expect(reader.requests == before)
        }
    }

    @Test("POST to the valid URL → 405 Method Not Allowed")
    func postIsMethodNotAllowed() async throws {
        try await withDirect { url, _, _ in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            let (_, response) = try await ephemeralHTTPSession().data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 405)
        }
    }

    @Test("Wrong path token → 404")
    func wrongTokenIs404() async throws {
        try await withDirect { url, _, _ in
            var components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            components.path = "/deadbeefdeadbeefdeadbeefdeadbeef/\(Self.direct)"
            let (_, response) = try await ephemeralHTTPSession().data(from: try #require(components.url))
            #expect((response as? HTTPURLResponse)?.statusCode == 404)
        }
    }

    @Test("A query string is stripped before the path is matched")
    func queryStringIsIgnored() async throws {
        try await withDirect { url, data, _ in
            var components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            components.query = "cachebust=1"
            let (body, response) = try await ephemeralHTTPSession().data(from: try #require(components.url))
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(body == data)
        }
    }

    @Test("Two range requests on one connection both return correct bytes, and the share is read for those bytes alone")
    func keepAliveSequentialRequestsBothSucceed() async throws {
        try await withDirect { url, data, reader in
            let before = reader.bytesRead
            let heads = Self.request(url, "Range: bytes=0-999\r\n")
                + Self.request(url, "Range: bytes=1000-1999\r\nConnection: close\r\n")
            let responses = WireResponse.all(in: try await Self.exchange(url, heads))

            #expect(responses.map(\.status) == [206, 206])
            #expect(responses.map(\.body) == [data.subdata(in: 0..<1000), data.subdata(in: 1000..<2000)])
            #expect(reader.bytesRead - before == 2000)
        }
    }

    @Test("stop() refuses new connections, and stopping again changes nothing", arguments: [Self.direct, Self.bridged])
    func stopRefusesNewConnections(name: String) async throws {
        let file = try await Self.start(InMemoryRandomAccessReader(data: try BridgeFixture.data(name)), named: name)
        let url = file.delivery.url
        await file.stop()
        await file.stop()

        let error = await #expect(throws: URLError.self) {
            _ = try await ephemeralHTTPSession(timeout: 3).data(from: url)
        }
        // A closed port refuses at once; a timeout would mean the listener was still accepting.
        #expect(error?.code != .timedOut, "a stopped delivery must refuse the connection, not hang")
    }

    @Test("A delivery whose clients reset mid-download lets go of its reader once it stops")
    func resetClientsDoNotPinTheDelivery() async throws {
        let freed = WeakReader()
        var downloads: [StalledDownload] = []
        do {
            let reader = CountingReader(Self.large)
            freed.reader = reader
            let file = try await Self.start(reader, named: "large.mp4")
            downloads = try (0..<4).map { _ in try StalledDownload(url: file.delivery.url) }
            // Each response's first read is 256 KB; then the sends park against full buffers.
            let parked = QuietPoll()
            await untilSettled {
                try? await Task.sleep(for: .milliseconds(20))
                return parked.isQuiet(afterReading: reader.bytesRead, atLeast: 4 << 18)
            }
            downloads.prefix(2).forEach { $0.reset() }
            await file.stop()
        }
        await untilSettled { freed.reader == nil }
        downloads.forEach { $0.close() }
    }

    // MARK: - Malformed request heads
    //
    // URLSession will not send any of these, so they go out over a raw socket. Each must close
    // the connection without a response rather than answer or hang.

    @Test("A malformed request line closes the connection with no response")
    func malformedRequestLineClosesSilently() async throws {
        try await withDirect { url, _, _ in
            let response = try await Self.exchange(url, "HELLO\r\n\r\n")
            #expect(response.isEmpty)
        }
    }

    @Test("EOF before the head terminator closes the connection with no response")
    func truncatedHeadClosesSilently() async throws {
        try await withDirect { url, _, _ in
            let response = try await Self.exchange(url, "GET \(url.path) HTTP/1.1\r\nHost: x\r\n", halfClosing: true)
            #expect(response.isEmpty)
        }
    }

    @Test("A head past the size cap is rejected without a response")
    func oversizedHeadIsRejected() async throws {
        try await withDirect { url, _, _ in
            // Never terminated, and past the server's cap of 16 KiB.
            let head = "GET \(url.path) HTTP/1.1\r\nX-Filler: \(String(repeating: "a", count: 16 << 10))\r\n"
            let response = try await Self.exchange(url, head)
            #expect(response.isEmpty)
        }
    }

    @Test("Connection: close is honored — the response is served, then the socket closes")
    func connectionCloseIsHonored() async throws {
        try await withDirect { url, data, _ in
            let head = Self.request(url, "Range: bytes=0-9\r\nConnection: close\r\n")
            let response = try await Self.exchange(url, head)
            let text = String(decoding: response, as: UTF8.self)
            #expect(text.hasPrefix("HTTP/1.1 206 Partial Content"))
            #expect(text.contains("Connection: close"))
            #expect(response.suffix(10) == data.subdata(in: 0..<10))
        }
    }

    @Test("An HTTP/1.0 request defaults to close and still gets its body")
    func http10DefaultsToClose() async throws {
        try await withDirect { url, data, _ in
            let response = try await Self.exchange(url, "GET \(url.path) HTTP/1.0\r\nHost: x\r\nRange: bytes=0-9\r\n\r\n")
            let text = String(decoding: response, as: UTF8.self)
            #expect(text.hasPrefix("HTTP/1.1 206 Partial Content"))
            #expect(text.contains("Connection: close"))
            #expect(response.suffix(10) == data.subdata(in: 0..<10))
        }
    }

    // MARK: - A bridged file

    private func withBridged(
        _ name: String = MediaDeliveryHTTPTests.bridged, reading reader: (any RandomAccessReading)? = nil,
        _ body: (DeliveredFile) async throws -> Void
    ) async throws {
        let source: any RandomAccessReading = try reader ?? InMemoryRandomAccessReader(data: BridgeFixture.data(name))
        let file = try await Self.start(source, named: name)
        do {
            try await body(file)
        } catch {
            await file.stop()
            throw error
        }
        await file.stop()
    }

    /// The bodies of `paths` from a delivery of `name` whose reads all succeed.
    private func cleanBodies(_ paths: [String], of name: String = MediaDeliveryHTTPTests.bridged) async throws -> [Data] {
        var bodies: [Data] = []
        try await withBridged(name) { file in
            for path in paths { bodies.append(try await file.bytes(path)) }
        }
        return bodies
    }

    @Test("Each path under the token gets its answer: playlists and segments with their type, 404 for a path that names nothing")
    func pathsAreAnsweredWithTheirType() async throws {
        try await withBridged { file in
            var answers: [String] = []
            for path in ["master.m3u8", "v.m3u8", "a0.m3u8", "v-init.mp4", "a1-init.mp4", "v-0.m4s", "missing.bin", "v-99.m4s"] {
                let (_, response) = try await ephemeralHTTPSession().data(from: file.url(of: path))
                let http = try #require(response as? HTTPURLResponse)
                answers.append("\(http.statusCode) \(http.value(forHTTPHeaderField: "Content-Type") ?? "-")")
            }

            let playlist = "200 application/vnd.apple.mpegurl"
            #expect(answers == [playlist, playlist, playlist, "200 video/mp4", "200 video/mp4", "200 video/mp4", "404 -", "404 -"])
        }
    }

    @Test("a streamed body goes out as one chunk per fragment, with no length and no ranges, whatever Range asks")
    func streamedBodyIsChunked() async throws {
        let whole = try await cleanBodies(["v-0.m4s"])
        try await withBridged { file in
            let url = file.url(of: "v-0.m4s")
            let head = Self.request(url, "Range: bytes=3-9\r\nConnection: close\r\n")
            let response = try #require(WireResponse.all(in: try await Self.exchange(url, head)).first)

            #expect(response.status == 200)
            #expect(response.field("Transfer-Encoding") == "chunked")
            #expect(response.field("Content-Length") == nil && response.field("Accept-Ranges") == nil)
            #expect(response.isWhole)
            #expect(response.body == whole.first)
            #expect(response.chunks.count == 2)
            #expect(response.chunks.allSatisfy { boxTypes(in: $0)?.filter { $0 == "moof" }.count == 1 },
                    "\(response.chunks.map(boxTypes))")
        }
    }

    @Test("HEAD of a streamed resource answers its headers and starts nothing")
    func headOfStreamedResourceStartsNothing() async throws {
        let reader = CountingReader(try BridgeFixture.data(Self.bridged))
        try await withBridged(reading: reader) { file in
            let url = file.url(of: "v-1.m4s")
            let opened = reader.requests
            let head = Self.request(url, "Connection: close\r\n", method: "HEAD")
            let response = try await Self.exchange(url, head)
            let headRequests = reader.requests - opened
            _ = try await file.bytes("v-1.m4s")

            #expect(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 200 OK"))
            #expect(response.range(of: Data("\r\n\r\n".utf8))?.upperBound == response.endIndex)
            #expect(headRequests == 0)
            // The GET reads the block the HEAD would have.
            #expect(reader.requests > opened)
        }
    }

    @Test("a streamed body that fails before its first fragment is a 500, and the connection serves on")
    func streamFailingBeforeItsFirstPieceIs500() async throws {
        let whole = try await cleanBodies(["v-3.m4s"])
        let reader = FailingOnceReader(data: try BridgeFixture.data(Self.bridged))
        try await withBridged(reading: reader) { file in
            let url = file.url(of: "v-3.m4s")
            reader.failNextRead()
            let heads = Self.request(url) + Self.request(url, "Connection: close\r\n")
            let responses = WireResponse.all(in: try await Self.exchange(url, heads))

            #expect(responses.map(\.status) == [500, 200])
            #expect(responses.last?.isWhole == true)
            #expect(responses.last?.body == whole.first)
        }
    }

    @Test("a streamed body that fails after its first fragment closes the connection without the last chunk")
    func streamFailingLaterClosesWithoutTheLastChunk() async throws {
        let whole = try await cleanBodies(["a0-0.m4s"], of: Self.fourTracks)
        let reader = FailingOnceReader(data: try BridgeFixture.data(Self.fourTracks))
        try await withBridged(Self.fourTracks, reading: reader) { file in
            let url = file.url(of: "a0-0.m4s")
            reader.failNextRead()
            let raw = try await Self.exchange(url, Self.request(url))
            let response = try #require(WireResponse.all(in: raw).first)

            #expect(response.status == 200)
            #expect(!response.isWhole)
            // The fragment made before the failure goes out whole.
            #expect(response.chunks.count == 1)
            #expect(try whole[0].starts(with: #require(response.chunks.first)))
        }
    }

    @Test("a client that drops a streamed response is let go at once, while its segment's read is still out")
    func droppedClientCancelsTheProducer() async throws {
        let reader = HoldingReader(try BridgeFixture.data(Self.fourTracks), holdingReadsStartingIn: Self.blocksOneAndTwo)
        try await withBridged(Self.fourTracks, reading: reader) { file in
            let url = file.url(of: "a0-0.m4s")
            let client = try SocketClient(url)
            client.send(Self.request(url))
            let firstChunk = await client.receive(timeout: CITimeScale.seconds(5)) { WireResponse.all(in: $0).first?.chunks.count == 1 }
            await reader.waitForHeldRead()
            client.closeSending()
            let afterClose = await client.receive(timeout: CITimeScale.seconds(2))
            await reader.release()

            #expect(WireResponse.all(in: firstChunk.data).first?.chunks.count == 1)
            #expect(afterClose.closed, "the server held the connection until the read came back")
            #expect(WireResponse.all(in: afterClose.data).first?.isWhole == false)
        }
    }

    @Test("a request sent behind a streamed one on the same connection is answered after it")
    func pipelinedRequestIsAnsweredAfterTheStream() async throws {
        let whole = try await cleanBodies(["v-0.m4s", "v-1.m4s"])
        try await withBridged { file in
            let heads = Self.request(file.url(of: "v-0.m4s")) + Self.request(file.url(of: "v-1.m4s"), "Connection: close\r\n")
            let responses = WireResponse.all(in: try await Self.exchange(file.url(of: "v-0.m4s"), heads))

            #expect(responses.map(\.status) == [200, 200])
            #expect(responses.map(\.isWhole) == [true, true])
            #expect(responses.map(\.body) == whole)
        }
    }
}

/// The ISO boxes `data` holds, by type, when their sizes tile it exactly.
private func boxTypes(in data: Data) -> [String]? {
    var types: [String] = []
    var offset = data.startIndex
    while offset < data.endIndex {
        guard data.endIndex - offset >= 8 else { return nil }
        let size = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        guard size >= 8, data.endIndex - offset >= size else { return nil }
        types.append(String(decoding: data[offset + 4..<offset + 8], as: UTF8.self))
        offset += size
    }
    return types
}

/// Serves `data`, holding every read that starts in `held` until released.
private actor HoldingReader: RandomAccessReading {
    private let backing: InMemoryRandomAccessReader
    private let range: Range<UInt64>
    private var held: [CheckedContinuation<Void, Never>] = []
    private var arrival: CheckedContinuation<Void, Never>?
    private var released = false

    init(_ data: Data, holdingReadsStartingIn range: Range<UInt64>) {
        backing = InMemoryRandomAccessReader(data: data)
        self.range = range
    }

    var fileSize: UInt64 { get async throws { try await backing.fileSize } }

    func read(offset: UInt64, length: Int) async throws -> Data {
        if !released, range.contains(offset) {
            await withCheckedContinuation {
                held.append($0)
                arrival?.resume()
                arrival = nil
            }
        }
        return try await backing.read(offset: offset, length: length)
    }

    func waitForHeldRead() async {
        guard held.isEmpty else { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func release() {
        released = true
        held.forEach { $0.resume() }
        held = []
    }
}

/// Quiet once `bytes` has held still, and at `atLeast` or more, for ten polls in a row.
private final class QuietPoll: @unchecked Sendable {
    private var last = 0
    private var stablePolls = 0

    func isQuiet(afterReading bytes: Int, atLeast floor: Int) -> Bool {
        stablePolls = bytes >= floor && bytes == last ? stablePolls + 1 : 0
        last = bytes
        return stablePolls >= 10
    }
}

private final class WeakReader: @unchecked Sendable {
    weak var reader: CountingReader?
}
