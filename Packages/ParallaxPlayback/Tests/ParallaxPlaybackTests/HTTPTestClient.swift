import Foundation
import Network
import Synchronization
import ParallaxCoreTestSupport
import ParallaxTestScaling

/// A fresh ephemeral `URLSession` per call. The bridge suites must NOT share
/// `URLSession.shared`: its process-wide cache and connection pool leak state between tests that
/// bind and tear down a socket each, and it has no request timeout, so one wedged bridge would hang
/// the whole run instead of failing its own test.
///
/// `timeout` is a dev-hardware anti-hang ceiling, `CITimeScale`d on CI: loaded runners have been
/// measured taking 83s on loopback round-trips the bridge served correctly, and the untripped
/// ceiling fired `URLError -1001` on them.
func ephemeralHTTPSession(timeout: TimeInterval = 10) -> URLSession {
    let timeout = CITimeScale.interval(timeout)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    return URLSession(configuration: configuration)
}

/// Sends `bytes` verbatim to the bridge's socket and returns everything it sends back before
/// closing. `URLSession` refuses to emit the malformed/oversized request heads the bridge's
/// head-reader guards against, so those paths need a client that writes raw octets.
///
/// - Parameters:
///   - halfCloseAfterSend: signal EOF after writing, which is how the "client vanished mid-head"
///     case is expressed on the wire.
///   - timeout: hard bound on the whole exchange, `CITimeScale`d on CI like the session's. A bug
///     that leaves the bridge holding the socket open must fail its own test, not wedge the run.
func rawHTTPExchange(
    with url: URL,
    sending bytes: Data,
    halfCloseAfterSend: Bool = false,
    timeout: Duration = .seconds(5)
) async throws -> Data {
    let timeout = CITimeScale.seconds(timeout / .seconds(1))
    guard let host = url.host, let rawPort = url.port, let port = NWEndpoint.Port(rawValue: UInt16(rawPort)) else {
        throw RawClientError.missingURLComponent
    }
    // Creating, starting and cancelling an `NWConnection` reaches the kernel's network-policy
    // layer on the calling thread and can block there, so all three stay on this queue instead of
    // a Swift concurrency cooperative thread — a stuck lane would stall the whole test process.
    let queue = DispatchQueue(label: "raw-http-test-client")
    let connection = await withCheckedContinuation { (continuation: CheckedContinuation<NWConnection, Never>) in
        queue.async {
            continuation.resume(returning: NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp))
        }
    }

    defer { queue.async { connection.cancel() } }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let readyOnce = OnceBox()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: readyOnce.once { continuation.resume() }
            case .failed(let error): readyOnce.once { continuation.resume(throwing: error) }
            case .cancelled: readyOnce.once { continuation.resume(throwing: CancellationError()) }
            default: break
            }
        }
        queue.async { connection.start(queue: queue) }
    }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        // `.finalMessage` is what actually closes the sending side; `isComplete` alone only ends
        // the message, and the peer would keep waiting for more request bytes.
        connection.send(
            content: bytes,
            contentContext: halfCloseAfterSend ? .finalMessage : .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        )
    }

    // Cancelling on the deadline fails the pending receive, which ends the loop below.
    let deadline = Task {
        try? await Ceiling.expire(timeout)
        guard Task.isCancelled == false else { return }
        queue.async { connection.cancel() }
    }
    defer { deadline.cancel() }

    var received = Data()
    while true {
        // A close after unread request bytes surfaces as a reset rather than a clean FIN, and both
        // mean the same thing here: the server is done talking. Treat either as end-of-stream and
        // return whatever it managed to send.
        let outcome: (Data?, Bool)? = try? await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (data, isComplete)) }
            }
        }
        guard let (chunk, isComplete) = outcome else { break }
        if let chunk { received.append(chunk) }
        if isComplete { break }
    }
    return received
}

/// Single-shot latch for the connection-readiness continuation; `NWConnection` state callbacks are
/// serialised on one queue, so no lock is needed.
private final class OnceBox: @unchecked Sendable {
    private var fired = false
    func once(_ body: () -> Void) {
        if fired { return }
        fired = true
        body()
    }
}

/// One response as it came off a connection.
struct WireResponse {
    let head: String
    let body: Data
    /// A chunked body's chunks, in order.
    let chunks: [Data]
    /// The body's last chunk came, or all of its Content-Length.
    let isWhole: Bool

    var status: Int? { head.split(separator: " ").dropFirst().first.flatMap { Int($0) } }

    func field(_ name: String) -> String? {
        head.components(separatedBy: "\r\n").dropFirst().lazy.compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == name.lowercased() else { return nil }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }.first
    }

    /// The responses `data` holds, in order, up to the first that was cut off. None answers a HEAD.
    static func all(in data: Data) -> [WireResponse] {
        let lineEnd = Data("\r\n".utf8)
        var rest = data
        var responses: [WireResponse] = []
        while let headEnd = rest.range(of: lineEnd + lineEnd) {
            let head = String(decoding: rest[..<headEnd.lowerBound], as: UTF8.self)
            rest = rest[headEnd.upperBound...]
            let partial = WireResponse(head: head, body: Data(), chunks: [], isWhole: false)
            if partial.field("Transfer-Encoding") == "chunked" {
                var chunks: [Data] = []
                var isWhole = false
                while let sizeEnd = rest.range(of: lineEnd),
                      let size = Int(String(decoding: rest[..<sizeEnd.lowerBound], as: UTF8.self), radix: 16),
                      rest.endIndex - sizeEnd.upperBound >= size + 2 {
                    let start = sizeEnd.upperBound
                    let chunk = Data(rest[start..<start + size])
                    rest = rest[(start + size + 2)...]
                    if size == 0 {
                        isWhole = true
                        break
                    }
                    chunks.append(chunk)
                }
                responses.append(WireResponse(head: head, body: Data(chunks.joined()), chunks: chunks, isWhole: isWhole))
                if !isWhole { break }
            } else {
                let length = partial.field("Content-Length").flatMap { Int($0) } ?? 0
                let body = Data(rest.prefix(length))
                rest = rest.dropFirst(length)
                responses.append(WireResponse(head: head, body: body, chunks: [], isWhole: body.count == length))
                if body.count < length { break }
            }
        }
        return responses
    }
}

/// A client on a socket of its own that reads a response as it arrives, and can close its
/// sending side partway: to the server, a player closing the connection.
final class SocketClient: @unchecked Sendable {
    private let fd: Int32
    private let received = Mutex(Data())
    private let closed = Atomic(false)

    init(_ url: URL) throws {
        guard let host = url.host, let port = url.port else { throw RawClientError.missingURLComponent }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RawClientError.connectFailed }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            Darwin.close(fd)
            throw RawClientError.missingURLComponent
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            throw RawClientError.connectFailed
        }
        self.fd = fd
    }

    deinit { Darwin.close(fd) }

    func send(_ text: String) {
        let bytes = Array(text.utf8)
        _ = write(fd, bytes, bytes.count)
    }

    func closeSending() { shutdown(fd, SHUT_WR) }

    /// Everything received so far, once `enough` holds of it, the server has closed, or
    /// `timeout` has passed; and whether the server has closed.
    func receive(timeout: Duration, until enough: @escaping @Sendable (Data) -> Bool = { _ in false }) async -> (data: Data, closed: Bool) {
        let deadline = ContinuousClock.now + timeout
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                var buffer = [UInt8](repeating: 0, count: 1 << 16)
                while !closed.load(ordering: .relaxed), !enough(received.withLock { $0 }), ContinuousClock.now < deadline {
                    var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    guard poll(&ready, 1, 20) > 0 else { continue }
                    let count = read(fd, &buffer, buffer.count)
                    if count <= 0 {
                        closed.store(true, ordering: .relaxed)
                    } else {
                        received.withLock { $0.append(contentsOf: buffer[..<count]) }
                    }
                }
                continuation.resume(returning: (received.withLock { $0 }, closed.load(ordering: .relaxed)))
            }
        }
    }
}
