import Foundation
import Network
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
        try? await Task.sleep(for: timeout)
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

enum RawClientError: Error {
    case missingURLComponent
}
