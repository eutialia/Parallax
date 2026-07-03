import Foundation
import Network
import OSLog
import ParallaxCore

/// A localhost/LAN HTTP/1.1 range server fronting one `RandomAccessReading`, so `AVPlayer`
/// can stream an SMB-hosted file it otherwise can't open (`AVPlayer` speaks HTTP, not SMB).
///
/// The bridge serves exactly one file for the life of the session. Access control is a
/// 128-bit random path token — there is no other auth, so the URL must never be persisted
/// or shared. `stop()` tears the whole thing down.
///
/// Concurrency: an `actor` owning the `NWListener` and the set of live `NWConnection`s.
/// Network.framework delivers listener/connection callbacks on a dedicated serial
/// `DispatchQueue`; every callback hops back onto the actor via `Task { await self.… }`, so
/// all mutable state (`listener`, `connections`, `isStopped`) is touched only under actor
/// isolation. The shared `reader` serialises its own access, so multiple simultaneous
/// connections (AVPlayer probes with concurrent range requests) are independent.
public actor SMBHTTPBridge {

    private static let logger = Logger(subsystem: "Parallax", category: "SMBHTTPBridge")

    private let reader: any RandomAccessReading
    private let contentType: String

    /// `/<128-bit-hex-token>/<percent-encoded fileName>` — the only path we answer 200/206 for.
    private let expectedPath: String

    /// Serial queue for all Network.framework callbacks. One queue for the listener and every
    /// connection keeps callback ordering simple; real work happens on the actor.
    private let queue = DispatchQueue(label: "com.lhdev.parallax.smb-http-bridge")

    private var listener: NWListener?
    /// Live connections keyed by identity, so `stop()` can cancel every one and each handler
    /// can remove itself on close without a linear scan.
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var isStopped = false

    /// Body chunk size: read + send the file in 2 MiB slices so the whole file is never buffered.
    private static let chunkSize = 2 * 1024 * 1024
    /// Request-head cap: reject a head that doesn't terminate within 16 KiB (malformed / abusive).
    private static let maxHeadBytes = 16 * 1024

    public init(reader: any RandomAccessReading, fileName: String, contentType: String) {
        self.reader = reader
        self.contentType = contentType
        // 128-bit random token = two UInt64 draws from the system CSPRNG, lower-hex.
        var rng = SystemRandomNumberGenerator()
        let token = String(format: "%016llx%016llx", rng.next() as UInt64, rng.next() as UInt64)
        let encodedName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        self.expectedPath = "/\(token)/\(encodedName)"
    }

    // MARK: - Lifecycle

    /// Binds an `NWListener` on an ephemeral TCP port and returns the URL AVPlayer should open.
    ///
    /// The host is the primary LAN IPv4, falling back to `127.0.0.1`. **The LAN address is
    /// deliberate:** when AVPlayer hands off to AirPlay external playback, the receiver (Apple
    /// TV) fetches this URL *itself* — a loopback-only URL black-screens the receiver. On-device
    /// local playback works over the LAN address too, so one URL serves both.
    public func start() async throws -> URL {
        guard !isStopped else { throw BridgeError.stopped }
        guard listener == nil else { throw BridgeError.alreadyStarted }

        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
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
                    readyGuard.once { continuation.resume(throwing: BridgeError.stopped) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        guard let port = listener.port else { throw BridgeError.noPort }
        let host = LocalNetworkAddress.primaryIPv4() ?? "127.0.0.1"
        guard let url = URL(string: "http://\(host):\(port.rawValue)\(expectedPath)") else {
            throw BridgeError.noPort
        }
        return url
    }

    /// Idempotent. Cancels the listener and every open connection; in-flight sends unwind as
    /// their `receive`/`send` fail, releasing each serve loop's strong reference to `self`.
    public func stop() async {
        guard !isStopped else { return }
        isStopped = true
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        // A connection that raced in during/after `stop()` gets refused — never served.
        guard !isStopped, listener != nil else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                Task { await self?.remove(connection) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        Task { await self.serve(connection) }
    }

    private func remove(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    /// Keep-alive loop: read a request head, answer it, repeat until the client asks to close,
    /// the head is malformed, or the socket errors/EOFs. AVPlayer reuses one connection for
    /// many range requests, so looping (not one-shot) is required.
    private func serve(_ connection: NWConnection) async {
        do {
            while !isStopped {
                guard let head = try await readRequestHead(connection) else { break }
                guard let request = Self.parse(head) else { break } // malformed → close, no response
                let keepAlive = try await respond(connection, to: request)
                if !keepAlive { break }
            }
        } catch {
            // receive/send failure or EOF — normal connection teardown, nothing actionable.
        }
        connection.cancel()
        remove(connection)
    }

    // MARK: - Request reading / parsing

    /// Accumulates bytes until the `\r\n\r\n` head terminator, returning the head (through the
    /// terminator). Returns `nil` on EOF-before-head or if the head exceeds `maxHeadBytes`.
    /// Any pipelined bytes past the terminator are dropped — AVPlayer's GET/HEAD carry no body
    /// and it waits for each response before sending the next request.
    private func readRequestHead(_ connection: NWConnection) async throws -> Data? {
        var buffer = Data()
        let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // CRLFCRLF
        while buffer.count < Self.maxHeadBytes {
            let (chunk, isComplete) = try await receive(connection, maximumLength: Self.maxHeadBytes - buffer.count)
            if let chunk, !chunk.isEmpty {
                buffer.append(chunk)
                if let found = buffer.range(of: terminator) {
                    return buffer.subdata(in: buffer.startIndex..<found.upperBound)
                }
            }
            if isComplete { return nil } // EOF before a complete head
        }
        return nil // head exceeded the cap → malformed
    }

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
    private func respond(_ connection: NWConnection, to request: ParsedRequest) async throws -> Bool {
        let keepAlive = request.keepAlive

        guard request.path == expectedPath else {
            try await send(connection, Self.headerData(status: "404 Not Found", keepAlive: keepAlive))
            return keepAlive
        }
        guard request.method == "GET" || request.method == "HEAD" else {
            try await send(connection, Self.headerData(status: "405 Method Not Allowed", keepAlive: keepAlive))
            return keepAlive
        }

        let size = try await reader.fileSize
        let isHead = request.method == "HEAD"

        guard let rangeSpec = request.rangeSpec else {
            // No Range → 200 full body.
            let headers = Self.headerData(
                status: "200 OK", keepAlive: keepAlive,
                fields: [
                    ("Content-Type", contentType),
                    ("Accept-Ranges", "bytes"),
                    ("Content-Length", "\(size)"),
                ])
            try await send(connection, headers)
            if !isHead { try await streamBody(connection, start: 0, length: size) }
            return keepAlive
        }

        switch Self.resolveRange(rangeSpec, size: size) {
        case .unsatisfiable:
            let headers = Self.headerData(
                status: "416 Range Not Satisfiable", keepAlive: keepAlive,
                fields: [("Content-Range", "bytes */\(size)")])
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
            try await send(connection, headers)
            if !isHead { try await streamBody(connection, start: 0, length: size) }
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
            try await send(connection, headers)
            if !isHead { try await streamBody(connection, start: start, length: length) }
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

    /// Streams `[start, start+length)` in 2 MiB chunks. The next `reader.read` is issued only
    /// after the previous `connection.send` completes (`send` awaits its continuation), so the
    /// bridge never buffers more than one chunk — TCP/receiver backpressure gates the reader.
    private func streamBody(_ connection: NWConnection, start: UInt64, length: UInt64) async throws {
        var offset = start
        var remaining = length
        while remaining > 0 {
            let want = Int(min(UInt64(Self.chunkSize), remaining))
            let data = try await reader.read(offset: offset, length: want)
            if data.isEmpty { break } // pread EOF — stop rather than spin
            try await send(connection, data)
            offset += UInt64(data.count)
            remaining -= UInt64(data.count)
            if data.count < want { break } // short read = EOF
        }
    }

    // MARK: - Network.framework bridging

    private func receive(_ connection: NWConnection, maximumLength: Int) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, isComplete))
                }
            }
        }
    }

    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    // MARK: - Header formatting

    private static func headerData(status: String, keepAlive: Bool, fields: [(String, String)] = []) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        for (name, value) in fields { head += "\(name): \(value)\r\n" }
        // A status with no explicit body length still needs Content-Length: 0 for keep-alive.
        if !fields.contains(where: { $0.0 == "Content-Length" }) { head += "Content-Length: 0\r\n" }
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        return Data(head.utf8)
    }

    enum BridgeError: Error, Sendable {
        case stopped
        case alreadyStarted
        case noPort
    }
}

/// Single-shot latch for the `start()` readiness continuation. The `NWListener` state handler
/// runs only on the bridge's serial callback queue, so this needs no lock — `@unchecked
/// Sendable` is honest: mutation is externally serialised.
private final class ReadyGuard: @unchecked Sendable {
    private var fired = false
    func once(_ body: () -> Void) {
        if fired { return }
        fired = true
        body()
    }
}
