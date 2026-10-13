import Foundation
import Observation

/// Intercepts the SDK's real HTTP path so the SDK-backed clients (`DefaultJellyfinLibraryClient`,
/// `DefaultJellyfinPlaybackClient`, `DefaultJellyfinAuthClient`) can be driven end to end —
/// endpoint, verb, query and POST body on the way out, decoding on the way back — with no live
/// Jellyfin and no `URLSession.shared`.
///
/// Each instance owns a unique host, so a parallel Swift Testing run can never route one suite's
/// request into another's stub. Hand `configuration` to the client under test; it installs
/// `StubURLProtocol` on that transport only.
public final class StubHTTPTransport: Observable, @unchecked Sendable {

    /// One intercepted request, in the shape assertions actually need.
    public struct Exchange: Sendable {
        public let method: String
        public let url: URL
        public let headers: [String: String]
        public let body: Data?

        public var path: String { url.path }

        private var queryItems: [URLQueryItem] {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        }

        /// The first value for `name`, or nil when the parameter was omitted (the SDK drops nil
        /// parameters entirely, so absence IS the assertion for "we didn't send it").
        public func query(_ name: String) -> String? {
            queryItems.first { $0.name == name }?.value
        }

        /// Every value for a repeated parameter (`fields`, `enableImageTypes`, `ids`, …).
        public func queryValues(_ name: String) -> [String] {
            queryItems.filter { $0.name == name }.compactMap(\.value)
        }

        public var queryNames: Set<String> { Set(queryItems.map(\.name)) }

        public func decodedBody<T: Decodable>(_ type: T.Type) throws -> T {
            try JSONDecoder().decode(type, from: body ?? Data())
        }
    }

    /// What the stub answers with. Defaults to an empty JSON object so a test that only cares
    /// about the outgoing request doesn't have to author a response.
    public struct Reply: Sendable {
        public var status: Int
        public var headers: [String: String]
        public var body: Data
        /// When set, the request never gets a response: the load fails with this `URLError`, the way
        /// `URLSession` fails against a host that cannot be reached. `status`, `headers` and `body`
        /// are ignored.
        public var transportFailure: URLError.Code?

        public init(
            status: Int = 200,
            headers: [String: String] = ["Content-Type": "application/json"],
            body: Data = Data("{}".utf8)
        ) {
            self.status = status
            self.headers = headers
            self.body = body
        }

        public static func json(_ raw: String, status: Int = 200) -> Reply {
            Reply(status: status, body: Data(raw.utf8))
        }

        public static func encoded(_ value: some Encodable, status: Int = 200) -> Reply {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return Reply(status: status, body: (try? encoder.encode(value)) ?? Data("{}".utf8))
        }

        /// No response at all: the request throws `URLError(code)` instead of seeing an HTTP status.
        public static func failure(_ code: URLError.Code) -> Reply {
            var reply = Reply()
            reply.transportFailure = code
            return reply
        }

        /// A 2xx with no payload — what the fire-and-forget POSTs (`/Sessions/Playing`, …) return.
        public static let noContent = Reply(status: 204, headers: [:], body: Data())
    }

    public let baseURL: URL

    private let lock = NSLock()
    private var recorded: [Exchange] = []
    private var queuedReplies: [Reply] = []
    private var fallbackReply = Reply()
    private var responder: (@Sendable (Exchange) -> Reply)?
    private var holds: (@Sendable (String) -> Bool)?
    private var heldDeliveries: [() -> Void] = []
    /// Tells `Observations` the parked requests changed, so a wait on `heldReplyCount` re-reads it.
    private let registrar = ObservationRegistrar()

    public init() {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        baseURL = URL(string: "https://\(host)")!
        StubRegistry.shared.register(self, forHost: host)
    }

    deinit {
        if let host = baseURL.host { StubRegistry.shared.unregister(host: host) }
    }

    /// A transport wired to route through this stub. Ephemeral so nothing lands in a shared
    /// URL cache between tests.
    public var configuration: URLSessionConfiguration { Self.configuration }

    /// The same transport without naming a stub: it routes every live stub's host, so a client
    /// built before its server exists (a whole app graph) still reaches it.
    public static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    // MARK: - Programming

    /// The answer for every request that outlives the queued ones.
    public func always(_ reply: Reply) {
        lock.withLock { fallbackReply = reply }
    }

    /// Answers in order, one per request; the fallback takes over once they're spent. Used by the
    /// two-request `getItemDetail` path, where the second call must return different bytes.
    public func enqueue(_ replies: Reply...) {
        lock.withLock { queuedReplies.append(contentsOf: replies) }
    }

    /// Computes every answer from the request, for a stub that keeps state across requests (a fake
    /// server). Takes precedence over queued and fallback replies.
    public func respond(with responder: @escaping @Sendable (Exchange) -> Reply) {
        lock.withLock { self.responder = responder }
    }

    /// Parks every request whose path `holds` accepts, from now on, unanswered, until
    /// `releaseReplies()`. Lets a test look at what the client shows while the network is still out.
    public func holdReplies(where holds: @escaping @Sendable (_ path: String) -> Bool = { _ in true }) {
        lock.withLock { self.holds = holds }
    }

    /// Answers the parked requests, each computed now rather than when it arrived, and stops
    /// parking.
    public func releaseReplies() {
        let parked = lock.withLock {
            holds = nil
            defer { heldDeliveries.removeAll() }
            return heldDeliveries
        }
        announceHeldReplies()
        parked.forEach { $0() }
    }

    /// How many requests are parked, waiting for `releaseReplies()`.
    public var heldReplyCount: Int {
        registrar.access(self, keyPath: \.heldReplyCount)
        return lock.withLock { heldDeliveries.count }
    }

    /// On the main actor, where the waits observe: `Observations` installs its tracking after its
    /// read returns, so a change announced from a URL loading thread in that gap would be lost.
    private func announceHeldReplies() {
        Task { @MainActor in registrar.withMutation(of: self, keyPath: \.heldReplyCount) {} }
    }

    /// Keeps `delivery` for `releaseReplies()` when replies to `path` are held. False means answer now.
    fileprivate func park(_ path: String, _ delivery: @escaping () -> Void) -> Bool {
        let parked = lock.withLock {
            guard holds?(path) == true else { return false }
            heldDeliveries.append(delivery)
            return true
        }
        if parked { announceHeldReplies() }
        return parked
    }

    // MARK: - Reading back

    public var exchanges: [Exchange] { lock.withLock { recorded } }

    /// The single recorded exchange. Most tests issue exactly one request, and asserting that
    /// there was exactly one is itself part of the contract (no accidental extra round-trip).
    public func onlyExchange() throws -> Exchange {
        let all = exchanges
        guard all.count == 1 else {
            throw StubError.unexpectedExchangeCount(all.count)
        }
        return all[0]
    }

    public enum StubError: Error { case unexpectedExchangeCount(Int) }

    // MARK: - URLProtocol plumbing

    fileprivate func handle(_ request: URLRequest) -> Reply {
        let exchange = Exchange(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.readBody(of: request)
        )
        let responder = lock.withLock {
            recorded.append(exchange)
            return self.responder
        }
        if let responder { return responder(exchange) }
        return lock.withLock {
            queuedReplies.isEmpty ? fallbackReply : queuedReplies.removeFirst()
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
        let request = request
        let deliver = {
            let reply = transport.handle(request)
            if let code = reply.transportFailure {
                self.client?.urlProtocol(self, didFailWithError: URLError(code))
                return
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: reply.status,
                httpVersion: "HTTP/1.1",
                headerFields: reply.headers
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !reply.body.isEmpty {
                self.client?.urlProtocol(self, didLoad: reply.body)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        // A held reply is delivered back on this loading thread's run loop: the client expects
        // its callbacks on the thread that called `startLoading`.
        let runLoop = CFRunLoopGetCurrent()
        let parked = transport.park(url.path) {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, deliver)
            CFRunLoopWakeUp(runLoop)
        }
        if !parked { deliver() }
    }

    override func stopLoading() {}
}
