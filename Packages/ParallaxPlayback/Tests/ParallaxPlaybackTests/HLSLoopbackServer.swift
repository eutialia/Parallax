import Foundation
import Network

/// A one-file HTTP/1.1 loopback server, just enough for AVFoundation to start an HLS load
/// against it and then be cut off mid-stream.
///
/// It exists because a *closed* port is the wrong failure to test the diagnosis with: the
/// connection is refused before any HTTP transaction happens, so `AVPlayerItem.accessLog()` and
/// `errorLog()` are both empty and the item's failure carries nothing but a CoreMedia code —
/// which is precisely the device symptom the diagnosis was written to see past. To exercise the
/// access/error logs at all, at least one request has to SUCCEED and a later one has to die
/// after the connection was established. That is what `respond` encodes: a route returns bytes,
/// or `nil` to accept the request and hang up on it with no response — the client-visible shape
/// of a Jellyfin transcode job being killed underneath an in-flight segment request
/// (`NSURLErrorDomain -1005`).
///
/// Loopback only, ephemeral port, no TLS, no keep-alive: one request per connection, then close.
final class HLSLoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "HLSLoopbackServer")
    private let respond: @Sendable (String) -> (contentType: String, body: Data)?
    private let lock = NSLock()
    private var requestedPaths: [String] = []

    /// - Parameter respond: maps a request path (no query) to a response, or `nil` to accept
    ///   the request and close the connection without answering it.
    init(respond: @escaping @Sendable (String) -> (contentType: String, body: Data)?) throws {
        self.respond = respond
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
    }

    /// Blocks until the listener has a port. `NWListener.port` is nil until it is `.ready`.
    func baseURL() async throws -> URL {
        for _ in 0..<200 {
            if let port = listener.port?.rawValue, port != 0, listener.state == .ready {
                return URL(string: "http://127.0.0.1:\(port)")!
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        struct NeverListened: Error {}
        throw NeverListened()
    }

    /// Every path the server was asked for, in order — the server's own record of the request
    /// sequence, to check the engine's report of it against.
    var pathsRequested: [String] {
        lock.withLock { requestedPaths }
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        // One request per connection: HTTP request lines are small and arrive in one segment on
        // loopback, so a single receive is enough to route on.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let target = text.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let path = target.split(separator: "?").first.map(String.init) ?? "/"
            self.lock.withLock { self.requestedPaths.append(path) }

            guard let response = self.respond(path) else {
                // Accepted, then hung up with nothing sent — the abort the client reads as
                // "the network connection was lost".
                connection.cancel()
                return
            }
            var head = "HTTP/1.1 200 OK\r\n"
            head += "Content-Type: \(response.contentType)\r\n"
            head += "Content-Length: \(response.body.count)\r\n"
            head += "Connection: close\r\n\r\n"
            var payload = Data(head.utf8)
            payload.append(response.body)
            connection.send(content: payload, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

extension HLSLoopbackServer {
    /// The shape of the failing device case: a multivariant playlist that resolves, pointing at
    /// a variant playlist the server accepts and then drops. AVFoundation logs the master in
    /// `accessLog()` (it transferred bytes) and the variant in `errorLog()` (it did not), and
    /// fails the item — because a variant playlist is required to reach `.readyToPlay`.
    static func servingOnlyTheMasterPlaylist() throws -> HLSLoopbackServer {
        try HLSLoopbackServer { path in
            guard path.hasSuffix("/master.m3u8") else { return nil }
            let playlist = """
                #EXTM3U
                #EXT-X-VERSION:7
                #EXT-X-STREAM-INF:BANDWIDTH=3506400,CODECS="hvc1.2.4.L150.B0,mp4a.40.2",RESOLUTION=1920x1080
                hls1/main/main.m3u8

                """
            return ("application/vnd.apple.mpegurl", Data(playlist.utf8))
        }
    }
}
