import Foundation
import Observation
import Darwin
import ParallaxCore

/// Broadcasts Jellyfin's discovery probe (`who is JellyfinServer?`) to
/// `255.255.255.255:7359` and collects JSON responses for a fixed window.
///
/// Side effect: starting a UDP broadcast is treated by iOS as local-network
/// activity, so it surfaces the system Local Network permission prompt at the
/// moment we call `start()` — typically app launch. Without that, the prompt
/// would otherwise be deferred until the first sign-in attempt.
///
/// On iOS 14+ broadcast requires the `com.apple.developer.networking.multicast`
/// entitlement on physical devices. The simulator does not enforce it, so this
/// works in development without the entitlement application; ship-to-device
/// requires the request to Apple to clear first.
@Observable
@MainActor
public final class LANServerDiscovery {
    public private(set) var discovered: [DiscoveredServer] = []
    public private(set) var isDiscovering: Bool = false

    private var seenIDs: Set<String> = []
    private var task: Task<Void, Never>?

    /// Source of one UDP broadcast pass. Injected so tests can drive discovery
    /// deterministically without touching real sockets; defaults to the live
    /// BSD-socket broadcast.
    private let broadcaster: @Sendable (TimeInterval) -> [Data]

    public init(broadcaster: (@Sendable (TimeInterval) -> [Data])? = nil) {
        self.broadcaster = broadcaster ?? LANServerDiscovery.broadcast
    }

    /// Starts discovery. Up to `retries` additional passes run (spaced by
    /// `retryInterval`) until at least one server is found — this catches a late
    /// Local Network permission grant during the launch window, since iOS keeps
    /// the app active through the permission alert and exposes no authorization
    /// status to observe the grant. Idempotent: calling while a run is in flight
    /// is a no-op; calling after one finishes starts a fresh, additive run
    /// (results dedupe by server id).
    public func start(timeout: TimeInterval = 1.5, retries: Int = 0, retryInterval: Duration = .seconds(2)) {
        guard task == nil else { return }
        Log.network.info("LAN discovery started (timeout=\(timeout)s, retries=\(retries))")
        isDiscovering = true
        let broadcaster = self.broadcaster
        task = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                let responses = await Task.detached(priority: .utility) { broadcaster(timeout) }.value
                guard let self else { return }
                self.ingest(responses)
                // Stop as soon as we've found a server, or once retries are spent.
                if !self.discovered.isEmpty || attempt >= retries { break }
                attempt += 1
                do {
                    try await Task.sleep(for: retryInterval)
                } catch {
                    break  // cancelled
                }
            }
            self?.didFinish()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        isDiscovering = false
    }

    private func ingest(_ responses: [Data]) {
        let before = discovered.count
        for data in responses {
            guard let server = Self.parseResponse(data),
                  seenIDs.insert(server.id).inserted else { continue }
            discovered.append(server)
        }
        let added = discovered.count - before
        Log.network.info("LAN discovery pass: \(responses.count) response(s), \(added) new server(s)")
    }

    private func didFinish() {
        isDiscovering = false
        task = nil
    }

    /// Parses one UDP response payload. Returns nil for malformed JSON or an
    /// unusable address. Internal for test coverage of the wire format.
    nonisolated internal static func parseResponse(_ data: Data) -> DiscoveredServer? {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(JellyfinDiscoveryEnvelope.self, from: data),
              let url = URL(string: envelope.address),
              url.host != nil else { return nil }
        return DiscoveredServer(id: envelope.id, name: envelope.name, address: url)
    }

    // MARK: - BSD socket broadcast (off-main)
    //
    // Apple's Network.framework `NWConnection` does not reliably support UDP
    // broadcast on iPadOS 26 (sendmsg returns EACCES even with the multicast
    // entitlement; DTS recommends BSD sockets). The protocol payload itself is
    // trivial, so we use Darwin's socket APIs directly.

    nonisolated private static func broadcast(timeout: TimeInterval) -> [Data] {
        let sock = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else {
            Log.network.error("LANServerDiscovery: socket() failed errno=\(errno)")
            return []
        }
        defer { Darwin.close(sock) }

        var enable: Int32 = 1
        guard setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &enable, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            Log.network.error("LANServerDiscovery: SO_BROADCAST failed errno=\(errno)")
            return []
        }

        // Short per-recv timeout so the loop can observe Task cancellation and
        // exit the overall window promptly instead of blocking on a single
        // recvfrom for the entire duration.
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = UInt16(7359).bigEndian
        dest.sin_addr.s_addr = INADDR_BROADCAST.bigEndian

        let payload = Array("who is JellyfinServer?".utf8)
        let sent = payload.withUnsafeBufferPointer { buf -> Int in
            withUnsafePointer(to: &dest) { dPtr in
                dPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    sendto(sock, buf.baseAddress, buf.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == payload.count else {
            Log.network.error("LANServerDiscovery: sendto returned \(sent) errno=\(errno)")
            return []
        }

        var responses: [Data] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if Task.isCancelled { break }
            var from = sockaddr()
            var fromLen = socklen_t(MemoryLayout<sockaddr>.size)
            let n = buffer.withUnsafeMutableBufferPointer { rx -> Int in
                recvfrom(sock, rx.baseAddress, rx.count, 0, &from, &fromLen)
            }
            if n > 0 {
                responses.append(Data(buffer[0..<n]))
            } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                continue
            } else {
                break
            }
        }
        return responses
    }
}

private struct JellyfinDiscoveryEnvelope: Decodable {
    let address: String
    let id: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case address = "Address"
        case id = "Id"
        case name = "Name"
    }
}
