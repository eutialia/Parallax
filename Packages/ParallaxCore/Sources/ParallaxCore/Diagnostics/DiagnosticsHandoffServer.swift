import Foundation
import Network

/// Serves one diagnostics export over the LAN so it can be fetched from another device.
///
/// **Why this exists.** tvOS has no share sheet: `ShareLink` is `@available(tvOS, unavailable)` and
/// `UIActivityViewController` is `__TVOS_PROHIBITED`. There is no Files app, no AirDrop, no
/// pasteboard — an Apple TV simply has no built-in way to hand a file to a person. So the app shows
/// a URL on the television and serves the file itself; the user opens it on a phone or a Mac on the
/// same network and gets a plain text download. iOS keeps the share sheet and uses this only when
/// somebody would rather pull the file over the network.
///
/// **Access control is a SHORT path token plus the server's lifetime.** Unlike `SMBHTTPBridge` —
/// which mints a 128-bit token because a media URL is handed to a player, not to a person — this URL
/// has to be READ OFF A TELEVISION AND TYPED on a phone, so a 32-hex token would make the feature
/// unusable. Four characters from an unambiguous alphabet is the compromise: still one glance and a
/// few taps, but it takes the LAN from "anyone may fetch this" to "anyone who can see the screen".
///
/// That matters because the payload is not as harmless as it first looks. Even with
/// `DiagnosticsRedaction` scrubbing browsed paths, the log still carries host names, share names and
/// a full timeline of when the device was used. Serving that to any device on the network for as
/// long as the screen is up is more than the feature needs.
///
/// The token is not doing heavy lifting on its own and is not meant to: what bounds the exposure is
/// the combination — an ephemeral port, on the LAN only, for exactly as long as the diagnostics
/// screen is open, after the user explicitly asked for it, behind a token a passer-by does not have.
///
/// **Concurrency.** An `actor` owning the listener and its connections, with every
/// Network.framework callback hopping back onto it — the shape `SMBHTTPBridge` already proved. The
/// payload is captured once at `start`, so a serve never touches the log file while it is being
/// appended to.
public actor DiagnosticsHandoffServer {

    /// Where the file can be fetched, and the display string the tvOS screen puts on the television.
    public struct Endpoint: Sendable {
        public let url: URL
        /// `192.168.1.42:53187/k3xq` — and, deliberately, the whole thing somebody has to type.
        /// Named for what it was before the token; it is still "the address, in full".
        public let hostAndPort: String
    }

    private let payload: Data
    private let fileName: String

    /// The one path this server answers on. Regenerated per instance, so a token seen once is dead
    /// as soon as the screen closes.
    private let token = DiagnosticsHandoffServer.makeToken()

    /// Four characters, from an alphabet with no `0`/`O` or `1`/`l`/`I` — this gets read off a
    /// television across a room and typed on a phone, so a misread character costs the user a retry.
    /// ~923k combinations against a listener that lives for a minute is plenty to stop a casual
    /// fetch, which is all it is for.
    private static func makeToken() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<4).compactMap { _ in alphabet.randomElement() })
    }

    /// Network.framework callbacks, and every listener/connection create/start/cancel — those reach
    /// the kernel's network policy layer on the CALLING thread and can block there, which must never
    /// happen on a cooperative pool thread. Same discipline as `SMBHTTPBridge`.
    private let queue = DispatchQueue(label: "com.lhdev.parallax.diagnostics-handoff")

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var isStopped = false

    /// - Parameters:
    ///   - payload: the whole export, read into memory before the server starts. Roughly
    ///     `DiagnosticsSink.recordByteCap` per retained session — but not strictly: session headers
    ///     and crash reports are written UNCAPPED by design, since a report that lost its stack to a
    ///     byte budget would defeat the point. So budget for a few MB across all runs, not the cap.
    ///   - fileName: what the browser should save it as.
    public init(payload: Data, fileName: String) {
        self.payload = payload
        self.fileName = fileName
    }

    /// Binds an ephemeral port on every interface and returns where to fetch the file.
    public func start() async throws -> Endpoint {
        guard !isStopped else { throw HandoffError.stopped }
        guard listener == nil else { throw HandoffError.alreadyStarted }

        let queue = self.queue
        let listener = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWListener, Error>) in
            queue.async { continuation.resume(with: Result { try NWListener(using: .tcp, on: .any) }) }
        }
        guard !isStopped else {
            await offQueue { listener.cancel() }
            throw HandoffError.stopped
        }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.accept(connection) }
        }

        // Single-shot readiness: state callbacks are serialised on `queue`, but a `.failed` after a
        // `.ready` would otherwise resume the continuation twice.
        let ready = ReadyLatch()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: ready.once { continuation.resume() }
                case .failed(let error): ready.once { continuation.resume(throwing: error) }
                case .cancelled: ready.once { continuation.resume(throwing: HandoffError.stopped) }
                default: break
                }
            }
            queue.async { listener.start(queue: queue) }
        }

        guard let port = listener.port else { throw HandoffError.noPort }
        guard let host = await offQueue({ LocalNetworkAddress.primaryIPv4() }) else {
            await stop()
            throw HandoffError.offNetwork
        }
        let hostAndPort = "\(host):\(port.rawValue)/\(token)"
        guard let url = URL(string: "http://\(hostAndPort)") else { throw HandoffError.noPort }
        return Endpoint(url: url, hostAndPort: hostAndPort)
    }

    /// Idempotent teardown. The screen calls this on disappear, so the server's lifetime is the
    /// lifetime of the URL being on screen.
    public func stop() async {
        guard !isStopped else { return }
        isStopped = true
        let listener = self.listener
        let connections = Array(self.connections.values)
        self.listener = nil
        self.connections.removeAll()
        await offQueue {
            listener?.cancel()
            for connection in connections { connection.cancel() }
        }
    }

    // MARK: - Serving

    private func accept(_ connection: NWConnection) {
        guard !isStopped, listener != nil else {
            Task { await self.offQueue { connection.cancel() } }
            return
        }
        connections[ObjectIdentifier(connection)] = connection
        Task {
            let queue = self.queue
            await self.offQueue { connection.start(queue: queue) }
            await self.serve(connection)
        }
    }

    /// One request, one response, close. Unlike the playback bridge there is no keep-alive and no
    /// ranges: this serves a single small file to a browser that asked for it once.
    private func serve(_ connection: NWConnection) async {
        defer {
            connections.removeValue(forKey: ObjectIdentifier(connection))
        }
        do {
            guard let head = try await readHead(connection) else { return }
            let response = Self.response(for: head, fileName: fileName, payload: payload, token: token)
            try await send(connection, response)
        } catch {
            // A browser that hung up mid-transfer is not a failure worth reporting.
        }
        await offQueue { connection.cancel() }
    }

    /// Builds the whole response — status line, headers and body — for one request head.
    /// `static` and pure so the method rules are testable without a socket.
    ///
    /// Only the token path answers with the log; everything else is a 404, including the
    /// `/favicon.ico` a browser fetches on its own.
    ///
    /// The trailing-slash form is accepted because browsers and users both add one without thinking,
    /// and refusing it would look like a mistyped token rather than a deliberate rejection.
    static func response(for head: String, fileName: String, payload: Data, token: String) -> Data {
        let requestLine = head.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return headers(status: "400 Bad Request") }

        let method = String(parts[0]).uppercased()
        guard method == "GET" || method == "HEAD" else { return headers(status: "405 Method Not Allowed") }

        // Compared against the path only: a query string is somebody's browser adding tracking junk,
        // not a different resource.
        let path = String(parts[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        guard path == "/\(token)" || path == "/\(token)/" else { return headers(status: "404 Not Found") }

        var response = headers(
            status: "200 OK",
            fields: [
                // `text/plain` so a browser shows it inline; the filename hint still gives a sensible
                // name to whoever chooses to save it.
                ("Content-Type", "text/plain; charset=utf-8"),
                ("Content-Disposition", "inline; filename=\"\(sanitizedHeaderValue(fileName))\""),
                ("Content-Length", "\(payload.count)"),
                // The body is a diagnostics log. Nothing between the television and the phone should
                // keep a copy of it after the screen closes.
                ("Cache-Control", "no-store"),
            ]
        )
        if method == "GET" { response.append(payload) }
        return response
    }

    /// Strips the characters that could end a header line early or close the quoted string.
    ///
    /// The name is app-generated today, so injection is not reachable — but "not reachable" is the
    /// kind of guarantee that quietly stops being true, and the header is built by hand.
    private static func sanitizedHeaderValue(_ value: String) -> String {
        String(value.filter { $0 != "\r" && $0 != "\n" && $0 != "\"" })
    }

    private static func headers(status: String, fields: [(String, String)] = []) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        for (name, value) in fields { head += "\(name): \(value)\r\n" }
        if !fields.contains(where: { $0.0 == "Content-Length" }) { head += "Content-Length: 0\r\n" }
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8)
    }

    /// Reads until the `\r\n\r\n` head terminator, capped so a malformed client can't grow the
    /// buffer without bound.
    private func readHead(_ connection: NWConnection) async throws -> String? {
        var buffer = Data()
        let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        while buffer.count < Self.maxHeadBytes {
            let (chunk, isComplete) = try await receive(connection, maximumLength: Self.maxHeadBytes - buffer.count)
            if let chunk, !chunk.isEmpty {
                buffer.append(chunk)
                if let found = buffer.range(of: terminator) {
                    let head = buffer.subdata(in: buffer.startIndex..<found.upperBound)
                    return String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1)
                }
            }
            if isComplete { return nil }
        }
        return nil
    }

    static let maxHeadBytes = 8 * 1024

    // MARK: - Network.framework bridging

    private func offQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        let queue = self.queue
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

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

    public enum HandoffError: Error, Sendable, Equatable {
        case stopped
        case alreadyStarted
        case noPort
        /// No routable LAN address — the device is off the network, so nobody could reach the URL
        /// anyway. Surfaced rather than served on loopback, which would be a dead end on a television.
        case offNetwork
    }
}

/// Single-shot latch for the readiness continuation. Mutated only on the server's serial callback
/// queue, which is what `@unchecked Sendable` is asserting here.
private final class ReadyLatch: @unchecked Sendable {
    private var fired = false
    func once(_ body: () -> Void) {
        guard !fired else { return }
        fired = true
        body()
    }
}
