import AVFoundation
import Foundation
import Network
import Synchronization
import Testing
import ParallaxCore
import ParallaxPlayback

/// A fixture delivered the way `SMBDelivery` delivers a file, and read over HTTP from its URL.
struct DeliveredFile: Sendable {
    let delivery: MediaDelivery

    static func start(
        _ file: String, support: AVPlayerSupport = BridgeFixture.everyDecoder,
        clock: any Clock<Duration> = ContinuousClock()
    ) async throws -> DeliveredFile {
        try await start(reading: InMemoryRandomAccessReader(data: BridgeFixture.data(file)), named: file, support: support, clock: clock)
    }

    static func start(
        reading reader: any RandomAccessReading, named file: String,
        support: AVPlayerSupport = BridgeFixture.everyDecoder, clock: any Clock<Duration> = ContinuousClock()
    ) async throws -> DeliveredFile {
        DeliveredFile(delivery: try await MediaDelivery.start(
            reading: reader, fileName: file, support: support, scope: .loopback, clock: clock))
    }

    struct NotServed: Error {
        let path: String
        let status: Int?
    }

    func url(of path: String) -> URL { delivery.url.deletingLastPathComponent().appending(path: path) }

    func bytes(_ path: String) async throws -> Data {
        let (body, response) = try await ephemeralHTTPSession().data(from: url(of: path))
        let status = (response as? HTTPURLResponse)?.statusCode
        guard status == 200 else { throw NotServed(path: path, status: status) }
        return body
    }

    func text(_ path: String) async throws -> String { String(decoding: try await bytes(path), as: UTF8.self) }

    var master: String { get async throws { try await text(delivery.url.lastPathComponent) } }

    /// The length of each segment a media playlist lists, in its order.
    func segmentSeconds(of playlist: String) async throws -> [Double] {
        try await text(playlist).split(separator: "\n").compactMap { line in
            line.hasPrefix("#EXTINF:") ? Double(line.dropFirst(8).prefix { $0 != "," }) : nil
        }
    }

    /// The whole of a rendition as one file: its init segment and every segment, fetched in
    /// `order`, then put back in place.
    func rendition(_ name: String, fetchedIn order: (Range<Int>) -> [Int] = { $0.shuffled() }) async throws -> Data {
        let count = try await segmentSeconds(of: "\(name).m3u8").count
        var segments: [Int: Data] = [:]
        for index in order(0..<count) { segments[index] = try await bytes("\(name)-\(index).m4s") }
        return try await bytes("\(name)-init.mp4") + (0..<count).flatMap { segments[$0] ?? Data() }
    }

    func stop() async { await delivery.stop() }
}

/// A delivered fixture that AVPlayer has loaded and is ready to play, through a relay that
/// records what AVPlayer asked the delivery for.
@MainActor
struct PlayedFile {
    let file: DeliveredFile
    let relay: RecordingRelay
    let ready: ReadyPlayer

    var player: AVPlayer { ready.player }
    /// The file names AVPlayer asked for, in order: "master.m3u8", "v-3.m4s".
    var paths: [String] { relay.pathsRequested }

    init(_ name: String, support: AVPlayerSupport = BridgeFixture.everyDecoder) async throws {
        try await self.init(DeliveredFile.start(name, support: support))
    }

    init(_ file: DeliveredFile) async throws {
        self.file = file
        do {
            let relay = try RecordingRelay(forwardingTo: file.delivery.url)
            self.relay = relay
            ready = try await ReadyPlayer(playing: try await relay.url(for: file.delivery.url)) { "\(relay.pathsRequested)" }
        } catch {
            await file.stop()
            throw error
        }
    }

    func framesShown(from seconds: Double? = nil, for duration: Duration) async -> [ShownFrame] {
        await ready.framesShown(from: seconds, for: duration)
    }

    func stop() async {
        player.pause()
        await file.stop()
        relay.stop()
    }
}

/// A loopback TCP relay in front of an HTTP server, recording the path of each request that
/// passes through. Bytes go through unchanged and a close on either side closes the other, so
/// what the server sees of the client, a connection dropped mid-response included, is what it
/// would see without the relay.
final class RecordingRelay: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "RecordingRelay")
    private let requested = Mutex<[String]>([])

    init(forwardingTo url: URL) throws {
        let target = NWEndpoint.hostPort(
            host: NWEndpoint.Host(try #require(url.host())),
            port: try #require(url.port.flatMap { NWEndpoint.Port(rawValue: UInt16($0)) }))
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self, queue] client in
            guard let self else { return client.cancel() }
            let server = NWConnection(to: target, using: .tcp)
            let requests = RequestLines { path in self.requested.withLock { $0.append(path) } }
            client.start(queue: queue)
            server.start(queue: queue)
            Self.pipe(from: client, to: server, observing: requests.take)
            Self.pipe(from: server, to: client, observing: nil)
        }
        listener.start(queue: queue)
    }

    /// `url` with the relay's address in place of the server's.
    func url(for url: URL) async throws -> URL {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while clock.now < deadline {
            if listener.state == .ready, let port = listener.port?.rawValue,
               var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                parts.port = Int(port)
                return try #require(parts.url)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        struct NeverListened: Error {}
        throw NeverListened()
    }

    var pathsRequested: [String] { requested.withLock { $0 } }

    func stop() { listener.cancel() }

    /// Sends what `source` receives on to `sink`, one receive at a time, so a slow reader on
    /// one side slows the other as it would on a direct connection.
    private static func pipe(from source: NWConnection, to sink: NWConnection, observing observe: (@Sendable (Data) -> Void)?) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
            guard let data, !data.isEmpty else {
                if isComplete || error != nil { closeBoth(source, sink) }
                else { pipe(from: source, to: sink, observing: observe) }
                return
            }
            observe?(data)
            sink.send(content: data, completion: .contentProcessed { sendError in
                if sendError != nil || isComplete || error != nil { closeBoth(source, sink) }
                else { pipe(from: source, to: sink, observing: observe) }
            })
        }
    }

    private static func closeBoth(_ one: NWConnection, _ other: NWConnection) {
        one.cancel()
        other.cancel()
    }
}

/// The request heads of one client's stream, which may arrive split or several at once. A GET
/// has no body, so the stream is heads alone.
private final class RequestLines: Sendable {
    private let pending = Mutex(Data())
    private let record: @Sendable (String) -> Void

    init(record: @escaping @Sendable (String) -> Void) { self.record = record }

    @Sendable func take(_ data: Data) {
        let heads = pending.withLock { pending -> [Data] in
            pending.append(data)
            var heads: [Data] = []
            while let end = pending.range(of: Data("\r\n\r\n".utf8)) {
                heads.append(pending[..<end.lowerBound])
                pending = Data(pending[end.upperBound...])
            }
            return heads
        }
        for head in heads {
            let line = String(decoding: head.prefix { $0 != UInt8(ascii: "\r") }, as: UTF8.self)
            let target = line.split(separator: " ").dropFirst().first ?? ""
            record(String(target.split(separator: "?").first?.split(separator: "/").last ?? ""))
        }
    }
}
