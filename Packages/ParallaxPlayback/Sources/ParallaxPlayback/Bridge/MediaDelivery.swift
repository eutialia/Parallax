import Foundation
import ParallaxCore
import Synchronization

/// A file on its way to AVPlayer: the URL to load, and the server behind it.
public struct MediaDelivery: Sendable {
    public let url: URL
    private let server: LocalMediaServer

    public static let defaultProbeDeadline: Duration = .seconds(4)

    /// Reading the file produced no verdict, so nothing is known about its format.
    public enum ProbeFailure: Error {
        case timedOut
        /// The reader's own error, for the caller that knows how to classify it.
        case unreadable(any Error)
    }

    /// Reads what it must of `reader` under `probeDeadline`, picks the route, and starts the
    /// server for it. A file AVPlayer opens is served as it is. A Matroska file goes through
    /// the bridge when `bridging` is set, which costs its index and its first segment.
    ///
    /// Throws the `Unplayable` reason when the file cannot reach AVPlayer, a `ProbeFailure`
    /// when reading gave no verdict, or the server's own error when it cannot bind. The
    /// reader stays the caller's on every path: this never disconnects it.
    public static func start(
        reading reader: any RandomAccessReading,
        fileName: String,
        support: AVPlayerSupport,
        bridging: Bool = true,
        scope: LocalMediaServer.AddressScope = .lan,
        probeDeadline: Duration = defaultProbeDeadline,
        clock: any Clock<Duration>
    ) async throws -> MediaDelivery {
        let routed = await race(against: probeDeadline, on: clock) {
            try await responder(reading: reader, fileName: fileName, support: support, bridging: bridging)
        }
        guard let routed else { throw ProbeFailure.timedOut }
        let responder: any MediaResponder
        do {
            responder = try routed.get()
        } catch let reason as Unplayable {
            throw reason
        } catch {
            throw ProbeFailure.unreadable(error)
        }
        let server = LocalMediaServer(responder: responder)
        do {
            return MediaDelivery(url: try await server.start(scope: scope), server: server)
        } catch {
            await server.stop()
            throw error
        }
    }

    /// What serves the file. Throws an `Unplayable`, or the reader's own error.
    private static func responder(
        reading reader: any RandomAccessReading, fileName: String, support: AVPlayerSupport, bridging: Bool
    ) async throws -> any MediaResponder {
        switch DirectPlay.verdict(for: try await MediaProbe.probe(reader), support: support) {
        case .unplayable(.container(.mkv)) where bridging:
            do {
                return try await BridgeSession.open(reader)
            } catch let refusal as BridgeRefusal {
                throw Unplayable.refused(refusal)
            }
        case .unplayable(let reason):
            throw reason
        case .direct(let container):
            return FileRangeResponder(
                reader: reader, fileName: fileName,
                contentType: container == .mov ? "video/quicktime" : "video/mp4")
        }
    }

    /// Idempotent. The reader is released by its owner, after this returns.
    public func stop() async {
        await server.stop()
    }

    /// What the session cost the source. Readable after `stop()` too.
    public var stats: LocalMediaServer.Stats {
        get async { await server.stats }
    }

    /// Races `work` against `deadline`, abandoning the work if the deadline wins. Nil on
    /// timeout.
    ///
    /// Unstructured on purpose: a task group would await the child even after `cancelAll()`,
    /// so a wedged source stalls the caller until the source's own socket timeout. Abandoned
    /// work ends when its read returns and holds only memory.
    private static func race<Value: Sendable>(
        against deadline: Duration, on clock: any Clock<Duration>,
        _ work: @escaping @Sendable () async throws -> Value
    ) async -> Result<Value, any Error>? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<Value, any Error>?, Never>) in
            let latch = OneShotLatch(continuation)
            let working = Task { () -> Result<Value, any Error> in
                do { return .success(try await work()) } catch { return .failure(error) }
            }
            let timer = Task {
                guard (try? await clock.sleep(for: deadline)) != nil else { return }
                working.cancel()          // cooperative only: a wedged read ignores it
                latch.resume(nil)
            }
            Task {
                let result = await working.value
                timer.cancel()
                latch.resume(result)
            }
        }
    }
}

/// Resumes a `CheckedContinuation` exactly once. The work and the deadline can each try to
/// complete it, and a double resume traps.
private final class OneShotLatch<Value: Sendable>: Sendable {
    private let box: Mutex<CheckedContinuation<Value?, Never>?>

    init(_ continuation: CheckedContinuation<Value?, Never>) {
        box = Mutex(continuation)
    }

    func resume(_ value: Value?) {
        let continuation = box.withLock { stored -> CheckedContinuation<Value?, Never>? in
            defer { stored = nil }
            return stored
        }
        continuation?.resume(returning: value)
    }
}
