import Foundation

/// Intercepts the SDK's real HTTP path so the SDK-backed clients (`DefaultJellyfinLibraryClient`,
/// `DefaultJellyfinPlaybackClient`, `DefaultJellyfinAuthClient`) can be driven end to end —
/// endpoint, verb, query and POST body on the way out, decoding on the way back — with no live
/// Jellyfin and no `URLSession.shared`.
///
/// Each instance owns a unique host, so a parallel Swift Testing run can never route one suite's
/// request into another's stub. Hand `configuration` to the client under test; it installs
/// `StubURLProtocol` on that transport only.
final class StubHTTPTransport: @unchecked Sendable {

    /// One intercepted request, in the shape assertions actually need.
    struct Exchange: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data?

        var path: String { url.path }

        private var queryItems: [URLQueryItem] {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        }

        /// The first value for `name`, or nil when the parameter was omitted (the SDK drops nil
        /// parameters entirely, so absence IS the assertion for "we didn't send it").
        func query(_ name: String) -> String? {
            queryItems.first { $0.name == name }?.value
        }

        /// Every value for a repeated parameter (`fields`, `enableImageTypes`, `ids`, …).
        func queryValues(_ name: String) -> [String] {
            queryItems.filter { $0.name == name }.compactMap(\.value)
        }

        var queryNames: Set<String> { Set(queryItems.map(\.name)) }

        func decodedBody<T: Decodable>(_ type: T.Type) throws -> T {
            try JSONDecoder().decode(type, from: body ?? Data())
        }
    }

    /// What the stub answers with. Defaults to an empty JSON object so a test that only cares
    /// about the outgoing request doesn't have to author a response.
    struct Reply: Sendable {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: Data = Data("{}".utf8)

        static func json(_ raw: String, status: Int = 200) -> Reply {
            Reply(status: status, body: Data(raw.utf8))
        }

        static func encoded(_ value: some Encodable, status: Int = 200) -> Reply {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return Reply(status: status, body: (try? encoder.encode(value)) ?? Data("{}".utf8))
        }

        /// A 2xx with no payload — what the fire-and-forget POSTs (`/Sessions/Playing`, …) return.
        static let noContent = Reply(status: 204, headers: [:], body: Data())
    }

    let baseURL: URL

    private let lock = NSLock()
    private var recorded: [Exchange] = []
    private var queuedReplies: [Reply] = []
    private var fallbackReply = Reply()

    init() {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        baseURL = URL(string: "https://\(host)")!
        StubRegistry.shared.register(self, forHost: host)
    }

    deinit {
        if let host = baseURL.host { StubRegistry.shared.unregister(host: host) }
    }

    /// A transport wired to route through this stub. Ephemeral so nothing lands in a shared
    /// URL cache between tests.
    var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    // MARK: - Programming

    /// The answer for every request that outlives the queued ones.
    func always(_ reply: Reply) {
        lock.withLock { fallbackReply = reply }
    }

    /// Answers in order, one per request; the fallback takes over once they're spent. Used by the
    /// two-request `getItemDetail` path, where the second call must return different bytes.
    func enqueue(_ replies: Reply...) {
        lock.withLock { queuedReplies.append(contentsOf: replies) }
    }

    // MARK: - Reading back

    var exchanges: [Exchange] { lock.withLock { recorded } }

    var lastExchange: Exchange? { lock.withLock { recorded.last } }

    /// The single recorded exchange. Most tests issue exactly one request, and asserting that
    /// there was exactly one is itself part of the contract (no accidental extra round-trip).
    func onlyExchange() throws -> Exchange {
        let all = exchanges
        guard all.count == 1 else {
            throw StubError.unexpectedExchangeCount(all.count)
        }
        return all[0]
    }

    enum StubError: Error { case unexpectedExchangeCount(Int) }

    // MARK: - URLProtocol plumbing

    fileprivate func handle(_ request: URLRequest) -> Reply {
        lock.withLock {
            recorded.append(
                Exchange(
                    method: request.httpMethod ?? "GET",
                    url: request.url!,
                    headers: request.allHTTPHeaderFields ?? [:],
                    body: Self.readBody(of: request)
                )
            )
            return queuedReplies.isEmpty ? fallbackReply : queuedReplies.removeFirst()
        }
    }

    /// `URLSession` converts a `httpBody` into a stream before `URLProtocol` sees it, so the body
    /// has to be drained from `httpBodyStream` — reading `httpBody` alone silently yields nil and
    /// would make every POST-body assertion vacuous.
    private static func readBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}

/// Host → stub lookup. Weak so a finished test's stub deregisters itself; the host is a fresh
/// UUID per instance, so entries can never be confused for one another in the meantime.
private final class StubRegistry: @unchecked Sendable {
    static let shared = StubRegistry()

    private final class WeakBox {
        weak var value: StubHTTPTransport?
        init(_ value: StubHTTPTransport) { self.value = value }
    }

    private let lock = NSLock()
    private var boxesByHost: [String: WeakBox] = [:]

    func register(_ transport: StubHTTPTransport, forHost host: String) {
        lock.withLock { boxesByHost[host] = WeakBox(transport) }
    }

    func unregister(host: String) {
        lock.withLock { _ = boxesByHost.removeValue(forKey: host) }
    }

    func transport(forHost host: String) -> StubHTTPTransport? {
        lock.withLock { boxesByHost[host]?.value }
    }
}

final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return StubRegistry.shared.transport(forHost: host) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let host = url.host,
              let transport = StubRegistry.shared.transport(forHost: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let reply = transport.handle(request)
        let response = HTTPURLResponse(
            url: url,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: reply.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty {
            client?.urlProtocol(self, didLoad: reply.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
