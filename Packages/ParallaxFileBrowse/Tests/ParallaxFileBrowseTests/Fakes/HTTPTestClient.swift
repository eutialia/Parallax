import Foundation
import Network

/// A fresh ephemeral `URLSession` per call. The bridge suites must NOT share
/// `URLSession.shared`: its process-wide cache and connection pool leak state between tests that
/// bind and tear down a socket each, and it has no request timeout, so one wedged bridge would hang
/// the whole run instead of failing its own test.
func ephemeralHTTPSession(timeout: TimeInterval = 10) -> URLSession {
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
///   - timeout: hard bound on the whole exchange. A bug that leaves the bridge holding the socket
///     open must fail its own test, not wedge the run.
func rawHTTPExchange(
    with url: URL,
    sending bytes: Data,
    halfCloseAfterSend: Bool = false,
    timeout: Duration = .seconds(5)
) async throws -> Data {
    guard let host = url.host, let rawPort = url.port, let port = NWEndpoint.Port(rawValue: UInt16(rawPort)) else {
        throw RawClientError.missingURLComponent
    }
    let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
    let queue = DispatchQueue(label: "raw-http-test-client")

    defer { connection.cancel() }

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
        connection.start(queue: queue)
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
        connection.cancel()
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
