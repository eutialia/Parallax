import Foundation
import Network
import OSLog
import ParallaxCore
import Synchronization

/// A localhost/LAN HTTP/1.1 range server, so `AVPlayer` can stream a file it cannot open where
/// it lives (`AVPlayer` speaks HTTP, not SMB). What it serves is its `MediaResponder`'s to say.
///
/// The server serves one responder for the life of the session. Access control is a
/// 128-bit random path token. There is no other auth, so the URL must never be persisted
/// or shared. `stop()` tears the whole thing down.
///
/// Concurrency: an `actor` owning the `NWListener` and the set of live `NWConnection`s.
/// Network.framework delivers listener/connection callbacks on a dedicated serial
/// `DispatchQueue`; every callback hops back onto the actor via `Task { await self.… }`, so
/// all mutable state (`lifecycle`, `connections`) is touched only under actor
/// isolation. The responder and its readers serialise their own access, so multiple
/// simultaneous connections (AVPlayer probes with concurrent range requests) are independent.
public actor LocalMediaServer {

    private static let logger = Log.custom(category: "LocalMediaServer")
    private static let requestLog = Log.retained(category: "BridgeRequests")

    private let responder: any MediaResponder

    /// `/<128-bit-hex-token>/`. Only paths below it reach the responder.
    private let root: String

    /// Serial queue for all Network.framework callbacks. One queue for the listener and every
    /// connection keeps callback ordering simple; real work happens on the actor.
    ///
    /// It also hosts every create/start/cancel of an `NWListener`/`NWConnection` (see `offPool`):
    /// those calls reach the kernel's network-policy layer on the CALLING thread, and when that
    /// layer is degraded they can sit there for seconds. A Swift concurrency cooperative thread
    /// must never host a call like that — the pool is only as wide as the core count, so a couple
    /// of stuck lanes stall every unrelated task in the process.
    private let queue = DispatchQueue(label: "com.lhdev.parallax.local-media-server")

    private enum Lifecycle {
        case idle
        /// Built, and accepting connections; `start()` may still be waiting for it to be ready.
        case listening(NWListener)
        case stopped
    }

    private var lifecycle = Lifecycle.idle
    /// Live connections keyed by identity, so `stop()` can cancel every one and each handler
    /// can remove itself on close without a linear scan.
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    private var isStopped: Bool {
        if case .stopped = lifecycle { true } else { false }
    }

    /// Every request answered so far, in the order each ended.
    private(set) var records: [RequestRecord] = []
    /// Starts timing a request on the server's clock.
    private let stopwatch: @Sendable () -> @Sendable () -> Duration

    /// Body chunk ceiling: read + send the file in slices so the whole file is never buffered.
    private static let chunkSize = 2 * 1024 * 1024
    /// First-chunk size per response. Chunks DOUBLE per consumed chunk up to `chunkSize`
    /// (see `streamBody`): a seeky prober (one walking a container header to its index
    /// and then to the target sample opens, reads a little, and RESETS the connection per hop)
    /// wastes at most this much already-read SMB data per abort, instead of a full 2 MiB
    /// chunk per hop — over a VPN that waste dwarfed the useful reads. A well-behaved long
    /// stream (AVPlayer playback) reaches the 2 MiB ceiling within four sends, so steady
    /// throughput is unaffected.
    private static let initialChunkSize = 256 * 1024
    /// Request-head cap: reject a head that doesn't terminate within 16 KiB (malformed / abusive).
    fileprivate static let maxHeadBytes = 16 * 1024

    init(responder: any MediaResponder, clock: any Clock<Duration>) {
        self.responder = responder
        stopwatch = Self.stopwatch(on: clock)
        // 128-bit random token = two UInt64 draws from the system CSPRNG, lower-hex.
        var rng = SystemRandomNumberGenerator()
        let token = String(format: "%016llx%016llx", rng.next() as UInt64, rng.next() as UInt64)
        self.root = "/\(token)/"
    }

    // MARK: - Lifecycle

    /// Which address the returned URL advertises. The listener itself binds every interface
    /// either way — the scope only decides what the CLIENT connects to.
    public enum AddressScope: Sendable {
        /// The primary LAN IPv4 (fallback loopback). Required when an AirPlay receiver must
        /// fetch the URL itself — a loopback URL black-screens the receiver.
        case lan
        /// `127.0.0.1`. For strictly on-device clients: a VPN's policy
        /// layer (NECP) can RESET self-connections to LAN/link-local addresses ("connection
        /// reset by peer" on every transfer, observed on-device), but loopback is exempt
        /// from tunnel enforcement. Never AirPlay-able.
        case loopback
    }

    /// Binds an `NWListener` on an ephemeral TCP port and returns the URL the client should open.
    ///
    /// The `.lan` host is the primary LAN IPv4, falling back to `127.0.0.1`. **The LAN
    /// address is deliberate for playback:** when AVPlayer hands off to AirPlay external
    /// playback, the receiver (Apple TV) fetches this URL *itself* — a loopback-only URL
    /// black-screens the receiver. On-device local playback works over the LAN address too, so
    /// one URL serves both. Pass `.loopback` for on-device-only clients (see `AddressScope`).
    ///
    /// Called once, by the delivery that made the server, which calls `stop()` only after this
    /// returns or throws. A throw leaves the listener for `stop()` to cancel.
    func start(scope: AddressScope) async throws -> URL {
        let queue = self.queue
        let listener = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWListener, Error>) in
            queue.async { continuation.resume(with: Result { try NWListener(using: .tcp, on: .any) }) }
        }
        lifecycle = .listening(listener)

        listener.newConnectionHandler = { [weak self] connection in
            // Already on `queue` — Network.framework delivers this callback there.
            guard let self else { connection.cancel(); return }
            Task { await self.accept(connection) }
        }

        // Wait for `.ready` (assigns the port) or surface the bind failure. `ReadyGuard` makes
        // the continuation single-shot: state callbacks are serialised on `queue`, so a later
        // `.failed`/`.cancelled` after `.ready` can't double-resume.
        let readyGuard = ReadyGuard()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    readyGuard.once { continuation.resume() }
                case .failed(let error):
                    readyGuard.once { continuation.resume(throwing: error) }
                case .cancelled:
                    readyGuard.once { continuation.resume(throwing: ServerError.stopped) }
                default:
                    break
                }
            }
            queue.async { listener.start(queue: queue) }
        }

        guard let port = listener.port else { throw ServerError.noPort }
        let host: String = switch scope {
        // `getifaddrs` is another syscall that stays off the cooperative pool.
        case .lan: await offPool { LocalNetworkAddress.primaryIPv4() } ?? "127.0.0.1"
        case .loopback: "127.0.0.1"
        }
        guard let url = URL(string: "http://\(host):\(port.rawValue)\(root)\(responder.entryPath)") else {
            throw ServerError.noPort
        }
        return url
    }

    /// Idempotent. Cancels the listener and every open connection; in-flight sends unwind as
    /// their `receive`/`send` fail, releasing each serve loop's strong reference to `self`.
    func stop() async {
        let listener: NWListener?
        switch lifecycle {
        case .stopped: return
        case .listening(let live): listener = live
        case .idle: listener = nil
        }
        lifecycle = .stopped
        let connections = Array(self.connections.values)
        self.connections.removeAll()
        await offPool {
            listener?.cancel()
            for connection in connections { connection.cancel() }
        }
    }

    /// Starts timing on `clock`, and gives what has passed each time it is asked.
    static func stopwatch<C: Clock>(on clock: C) -> @Sendable () -> @Sendable () -> Duration
    where C.Duration == Duration {
        {
            let start = clock.now
            return { start.duration(to: clock.now) }
        }
    }

    /// Runs `body` on `queue` and resumes with its result — the hop that keeps Network.framework's
    /// blocking create/start/cancel calls off the cooperative pool (see `queue`).
    private func offPool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        let queue = self.queue
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        // A connection that raced in during/after `stop()` gets refused — never served.
        guard case .listening = lifecycle else {
            Task { await self.offPool { connection.cancel() } }
            return
        }
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { state in
            // A failed connection parks its pending completions until cancelled, and the serve
            // loop awaiting them holds the server.
            if case .failed = state { connection.cancel() }
        }
        Task {
            let queue = self.queue
            await self.offPool { connection.start(queue: queue) }
            await self.serve(connection)
        }
    }

    private func remove(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    /// Keep-alive loop: read a request head, answer it, repeat until the client asks to close,
    /// the head is malformed, or the socket errors/EOFs. AVPlayer reuses one connection for
    /// many range requests, so looping (not one-shot) is required.
    private func serve(_ connection: NWConnection) async {
        let input = ConnectionInput(connection)
        input.start()
        do {
            while !isStopped {
                guard let head = await input.nextHead() else { break }
                guard let request = Self.parse(head) else { break } // malformed → close, no response
                let elapsed = stopwatch()
                var exchange = Exchange()
                defer { record(request, exchange, after: elapsed()) }
                do {
                    let keepAlive = try await respond(connection, input, to: request, &exchange, elapsed)
                    if !keepAlive { break }
                } catch {
                    if exchange.ending == .complete { exchange.ending = .dropped }
                    throw error
                }
            }
        } catch {
            // receive/send failure or EOF — normal connection teardown, nothing actionable.
        }
        await offPool { connection.cancel() }
        remove(connection)
    }

    /// What one request has cost so far.
    private struct Exchange {
        var status = 0
        var firstByte: Duration?
        var bytesSent = 0
        var bytesFetched = 0
        var ending = RequestRecord.Ending.complete
    }

    private func record(_ request: ParsedRequest, _ exchange: Exchange, after duration: Duration) {
        let path = request.path.hasPrefix(root) ? String(request.path.dropFirst(root.count)) : nil
        let record = RequestRecord(
            resource: path.flatMap(responder.role(of:)) ?? "unknown", status: exchange.status,
            firstByte: exchange.firstByte, duration: duration, bytesSent: exchange.bytesSent,
            bytesFetched: exchange.bytesFetched, ending: exchange.ending)
        records.append(record)
        Self.requestLog.info("\(record)")
    }

    // MARK: - Request reading / parsing

    private struct ParsedRequest {
        let method: String
        let path: String
        /// The value after `bytes=` (e.g. `"1000-2999"`, `"1048000-"`), or nil if no Range.
        let rangeSpec: String?
        let keepAlive: Bool
    }

    private static func parse(_ head: Data) -> ParsedRequest? {
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else {
            return nil
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 3 else { return nil }

        let method = String(parts[0]).uppercased()
        var path = String(parts[1])
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        let version = String(parts[2]).uppercased()

        // HTTP/1.1 defaults to keep-alive; HTTP/1.0 defaults to close.
        var keepAlive = version != "HTTP/1.0"
        var rangeSpec: String?

        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "range":
                if value.lowercased().hasPrefix("bytes=") {
                    rangeSpec = String(value.dropFirst("bytes=".count))
                }
            case "connection":
                let lowered = value.lowercased()
                if lowered.contains("close") { keepAlive = false }
                else if lowered.contains("keep-alive") { keepAlive = true }
            default:
                break
            }
        }
        return ParsedRequest(method: method, path: path, rangeSpec: rangeSpec, keepAlive: keepAlive)
    }

    // MARK: - Response

    /// Answers one request, returning whether the connection should stay open.
    private func respond(
        _ connection: NWConnection, _ input: ConnectionInput, to request: ParsedRequest,
        _ exchange: inout Exchange, _ elapsed: @Sendable () -> Duration
    ) async throws -> Bool {
        let keepAlive = request.keepAlive

        guard request.path.hasPrefix(root) else {
            try await sendHead(connection, 404, "Not Found", keepAlive: keepAlive, &exchange)
            return keepAlive
        }
        guard request.method == "GET" || request.method == "HEAD" else {
            try await sendHead(connection, 405, "Method Not Allowed", keepAlive: keepAlive, &exchange)
            return keepAlive
        }
        guard let resource = await responder.resource(at: String(request.path.dropFirst(root.count))) else {
            try await sendHead(connection, 404, "Not Found", keepAlive: keepAlive, &exchange)
            return keepAlive
        }
        let contentType = resource.contentType
        let isHead = request.method == "HEAD"
        let reader: any RandomAccessReading
        switch resource.body {
        case .ranged(let ranged):
            reader = ranged
        case .streamed(let produce):
            return try await stream(
                connection, input, isHead ? nil : produce(), contentType: contentType, keepAlive: keepAlive,
                &exchange, elapsed)
        }

        let size = try await reader.fileSize

        guard let rangeSpec = request.rangeSpec else {
            // No Range → 200 full body.
            let headers = Self.headerData(
                status: "200 OK", keepAlive: keepAlive,
                fields: [
                    ("Content-Type", contentType),
                    ("Accept-Ranges", "bytes"),
                    ("Content-Length", "\(size)"),
                ])
            exchange.status = 200
            try await send(connection, headers)
            if !isHead { try await streamBody(connection, from: reader, start: 0, length: size, &exchange, elapsed) }
            return keepAlive
        }

        switch Self.resolveRange(rangeSpec, size: size) {
        case .unsatisfiable:
            let headers = Self.headerData(
                status: "416 Range Not Satisfiable", keepAlive: keepAlive,
                fields: [("Content-Range", "bytes */\(size)")])
            exchange.status = 416
            try await send(connection, headers)
            return keepAlive

        case .ignore:
            // Malformed / unsupported (e.g. suffix `bytes=-500`) Range: RFC 7233 says ignore it
            // and serve the full representation. AVPlayer never sends suffix ranges for
            // progressive fetches, so this path is defensive.
            let headers = Self.headerData(
                status: "200 OK", keepAlive: keepAlive,
                fields: [
                    ("Content-Type", contentType),
                    ("Accept-Ranges", "bytes"),
                    ("Content-Length", "\(size)"),
                ])
            exchange.status = 200
            try await send(connection, headers)
            if !isHead { try await streamBody(connection, from: reader, start: 0, length: size, &exchange, elapsed) }
            return keepAlive

        case let .satisfiable(start, end):
            let length = end - start + 1
            let headers = Self.headerData(
                status: "206 Partial Content", keepAlive: keepAlive,
                fields: [
                    ("Content-Type", contentType),
                    ("Accept-Ranges", "bytes"),
                    ("Content-Range", "bytes \(start)-\(end)/\(size)"),
                    ("Content-Length", "\(length)"),
                ])
            exchange.status = 206
            try await send(connection, headers)
            if !isHead { try await streamBody(connection, from: reader, start: start, length: length, &exchange, elapsed) }
            return keepAlive
        }
    }

    private enum RangeResolution {
        case satisfiable(UInt64, UInt64)
        case unsatisfiable
        case ignore
    }

    /// Resolves `bytes=` range spec against `size`. `a-b` / `a-` map to satisfiable or
    /// unsatisfiable (`a >= size` → 416); anything else (suffix, garbage) → `.ignore` (200 full).
    private static func resolveRange(_ spec: String, size: UInt64) -> RangeResolution {
        let bounds = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let firstPart = bounds.first, let start = UInt64(firstPart) else {
            return .ignore // empty start (suffix range) or unparseable → ignore per RFC 7233
        }
        guard start < size else { return .unsatisfiable }

        var end = size - 1
        if bounds.count == 2, !bounds[1].isEmpty {
            guard let requested = UInt64(bounds[1]) else { return .ignore }
            end = min(requested, size - 1)
        }
        guard end >= start else { return .ignore }
        return .satisfiable(start, end)
    }

    /// Streams `[start, start+length)` in chunks that grow from `initialChunkSize` to
    /// `chunkSize` (doubling per consumed chunk — see `initialChunkSize` for why). The next
    /// `reader.read` is issued only after the previous `connection.send` completes (`send`
    /// awaits its continuation), so the server never buffers more than one chunk —
    /// TCP/receiver backpressure gates the reader, and an aborted connection surfaces as a
    /// failed send BEFORE the next (bigger) read is charged to the share.
    private func streamBody(
        _ connection: NWConnection, from reader: any RandomAccessReading, start: UInt64, length: UInt64,
        _ exchange: inout Exchange, _ elapsed: @Sendable () -> Duration
    ) async throws {
        var offset = start
        var remaining = length
        var chunk = Self.initialChunkSize
        while remaining > 0 {
            let want = Int(min(UInt64(chunk), remaining))
            let data = try await reader.read(offset: offset, length: want)
            exchange.bytesFetched += data.count
            if data.isEmpty { break } // pread EOF — stop rather than spin
            try await sendBody(connection, data, counting: data.count, &exchange, elapsed)
            offset += UInt64(data.count)
            remaining -= UInt64(data.count)
            if data.count < want { break } // short read = EOF
            chunk = min(chunk * 2, Self.chunkSize)
        }
    }

    /// Answers with a body made as it is sent: `200`, chunked, one chunk per piece, and any
    /// `Range` ignored, since the length is not known up front. The first piece is made before
    /// any header, so a failure up to there is still a `500`. A failure after it closes the
    /// connection without the last chunk, so the client never takes a cut-off body as whole.
    /// With no producer, for `HEAD`, only the headers go out.
    private func stream(
        _ connection: NWConnection, _ input: ConnectionInput, _ producer: (any BodyProducer)?,
        contentType: String, keepAlive: Bool, _ exchange: inout Exchange, _ elapsed: @Sendable () -> Duration
    ) async throws -> Bool {
        let headers = Self.headerData(
            status: "200 OK", keepAlive: keepAlive, fields: [("Content-Type", contentType)], chunked: true)
        guard let producer else {
            exchange.status = 200
            try await send(connection, headers)
            return keepAlive
        }
        input.whileStreaming { producer.cancel() }
        defer {
            input.doneStreaming()
            producer.cancel()
            exchange.bytesFetched = producer.bytesFetched
        }
        var piece: Data?
        do {
            piece = try await producer.next()
        } catch {
            if input.hasEnded {
                exchange.ending = .dropped
                return false
            }
            Self.logger.error("no first piece for a request: \(error)")
            exchange.ending = .failed(afterBytes: 0, by: error)
            try await sendHead(connection, 500, "Internal Server Error", keepAlive: keepAlive, &exchange)
            return keepAlive
        }
        exchange.status = 200
        try await send(connection, headers)
        do {
            while let data = piece {
                try await sendBody(
                    connection, Data("\(String(data.count, radix: 16))\r\n".utf8) + data + Data("\r\n".utf8),
                    counting: data.count, &exchange, elapsed)
                piece = try await producer.next()
            }
        } catch {
            if input.hasEnded {
                exchange.ending = .dropped
            } else {
                Self.logger.error("a streamed body stopped: \(error)")
                exchange.ending = .failed(afterBytes: exchange.bytesSent, by: error)
            }
            return false
        }
        try await send(connection, Data("0\r\n\r\n".utf8))
        return keepAlive
    }

    // MARK: - Network.framework bridging

    /// A response with no body.
    private func sendHead(
        _ connection: NWConnection, _ status: Int, _ reason: String, keepAlive: Bool, _ exchange: inout Exchange
    ) async throws {
        exchange.status = status
        try await send(connection, Self.headerData(status: "\(status) \(reason)", keepAlive: keepAlive))
    }

    /// `bytes` of the body, which `data` carries with any framing around them.
    private func sendBody(
        _ connection: NWConnection, _ data: Data, counting bytes: Int, _ exchange: inout Exchange,
        _ elapsed: @Sendable () -> Duration
    ) async throws {
        try await send(connection, data)
        exchange.firstByte = exchange.firstByte ?? elapsed()
        exchange.bytesSent += bytes
    }

    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    // MARK: - Header formatting

    /// `chunked` for a body whose length is not known: its end is the last chunk.
    private static func headerData(
        status: String, keepAlive: Bool, fields: [(String, String)] = [], chunked: Bool = false
    ) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        for (name, value) in fields { head += "\(name): \(value)\r\n" }
        if chunked {
            head += "Transfer-Encoding: chunked\r\n"
        } else if !fields.contains(where: { $0.0 == "Content-Length" }) {
            // A status with no explicit body length still needs Content-Length: 0 for keep-alive.
            head += "Content-Length: 0\r\n"
        }
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        return Data(head.utf8)
    }

    enum ServerError: Error, Sendable {
        case stopped
        case noPort
    }
}

/// Single-shot latch for the `start()` readiness continuation. The `NWListener` state handler
/// runs only on the server's serial callback queue, so this needs no lock — `@unchecked
/// Sendable` is honest: mutation is externally serialised.
private final class ReadyGuard: @unchecked Sendable {
    private var fired = false
    func once(_ body: () -> Void) {
        if fired { return }
        fired = true
        body()
    }
}

/// What a client has sent that is not yet read. One `receive` stays outstanding for the
/// connection's life, so a client that closes or resets is seen at once, even while a response
/// is still being made; bytes that arrive ahead of time, a pipelined request, wait here.
private final class ConnectionInput: Sendable {
    private struct State {
        var buffered = Data()
        var hasEnded = false
        var waiter: CheckedContinuation<Void, Never>?
        var onEnd: (@Sendable () -> Void)?
    }

    private let connection: NWConnection
    private let state = Mutex(State())
    private static let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // CRLFCRLF

    init(_ connection: NWConnection) { self.connection = connection }

    var hasEnded: Bool { state.withLock { $0.hasEnded } }

    func start() { receiveNext() }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            let (ended, waiter, onEnd) = state.withLock { state in
                if let data { state.buffered.append(data) }
                // More unread than a request head may be is a client to stop listening to.
                state.hasEnded = isComplete || error != nil || state.buffered.count > LocalMediaServer.maxHeadBytes
                defer {
                    state.waiter = nil
                    if state.hasEnded { state.onEnd = nil }
                }
                return (state.hasEnded, state.waiter, state.hasEnded ? state.onEnd : nil)
            }
            waiter?.resume()
            onEnd?()
            if !ended { receiveNext() }
        }
    }

    /// The next request head, through its terminator. Nil when the connection ends first or the
    /// head runs past `maxHeadBytes`.
    func nextHead() async -> Data? {
        while true {
            let head = state.withLock { state -> Data?? in
                if let found = state.buffered.range(of: Self.terminator) {
                    let head = state.buffered.subdata(in: state.buffered.startIndex..<found.upperBound)
                    state.buffered = state.buffered.subdata(in: found.upperBound..<state.buffered.endIndex)
                    return .some(head)
                }
                return state.hasEnded || state.buffered.count >= LocalMediaServer.maxHeadBytes ? .some(nil) : .none
            }
            if let head { return head }
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state in
                    let ready = state.hasEnded || state.buffered.range(of: Self.terminator) != nil
                        || state.buffered.count >= LocalMediaServer.maxHeadBytes
                    if !ready { state.waiter = continuation }
                    return ready
                }
                if ready { continuation.resume() }
            }
        }
    }

    /// Calls `onEnd` once if the connection ends before `doneStreaming`, at once if it already has.
    func whileStreaming(_ onEnd: @escaping @Sendable () -> Void) {
        let ended = state.withLock { state in
            if !state.hasEnded { state.onEnd = onEnd }
            return state.hasEnded
        }
        if ended { onEnd() }
    }

    func doneStreaming() {
        state.withLock { $0.onEnd = nil }
    }
}
