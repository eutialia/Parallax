import Foundation
import ParallaxCore
import Synchronization

/// A file on its way to AVPlayer: the URL to load, and the server behind it.
public struct MediaDelivery: Sendable {
    public let url: URL
    private let server: LocalMediaServer

    public static let defaultProbeDeadline: Duration = .seconds(4)

    /// The probe produced no verdict, so nothing is known about the file's format.
    public enum ProbeFailure: Error {
        case timedOut
        /// The reader's own error, for the caller that knows how to classify it.
        case unreadable(any Error)
    }

    /// Probes `reader` under `probeDeadline`, picks the route, and starts what the route needs.
    ///
    /// Throws the `Unplayable` reason when AVPlayer cannot play the file, a `ProbeFailure`
    /// when the probe gave no verdict, or the server's own error when it cannot bind. The
    /// reader stays the caller's on every path: this never disconnects it.
    public static func start(
        reading reader: any RandomAccessReading,
        fileName: String,
        support: AVPlayerSupport,
        scope: LocalMediaServer.AddressScope = .lan,
        probeDeadline: Duration = defaultProbeDeadline,
        clock: any Clock<Duration>
    ) async throws -> MediaDelivery {
        guard let probed = await probe(reader, within: probeDeadline, on: clock) else {
            throw ProbeFailure.timedOut
        }
        let result: MediaProbeResult
        do {
            result = try probed.get()
        } catch {
            throw ProbeFailure.unreadable(error)
        }
        switch DirectPlay.verdict(for: result, support: support) {
        case .unplayable(let reason):
            throw reason
        case .direct(let container):
            let server = LocalMediaServer(
                reader: reader, fileName: fileName,
                contentType: container == .mov ? "video/quicktime" : "video/mp4")
            do {
                return MediaDelivery(url: try await server.start(scope: scope), server: server)
            } catch {
                await server.stop()
                throw error
            }
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

    /// Races a container probe against `deadline`, abandoning the probe if the deadline wins.
    /// Nil on timeout.
    ///
    /// Unstructured on purpose: a task group would await the probe child even after
    /// `cancelAll()`, so a wedged source stalls the caller until the source's own socket
    /// timeout. An abandoned probe ends when its read returns and holds only memory.
    private static func probe(
        _ reader: any RandomAccessReading, within deadline: Duration, on clock: any Clock<Duration>
    ) async -> ProbeResult? {
        await withCheckedContinuation { (continuation: CheckedContinuation<ProbeResult?, Never>) in
            let latch = OneShotLatch(continuation)
            let probe = Task { () -> ProbeResult in
                do { return .success(try await MediaProbe.probe(reader)) } catch { return .failure(error) }
            }
            let timer = Task {
                guard (try? await clock.sleep(for: deadline)) != nil else { return }
                probe.cancel()          // cooperative only: a wedged read ignores it
                latch.resume(nil)
            }
            Task {
                let result = await probe.value
                timer.cancel()
                latch.resume(result)
            }
        }
    }
}

private typealias ProbeResult = Result<MediaProbeResult, any Error>

/// Resumes a `CheckedContinuation` exactly once. The probe and the deadline can each try to
/// complete it, and a double resume traps.
private final class OneShotLatch: Sendable {
    private let box: Mutex<CheckedContinuation<ProbeResult?, Never>?>

    init(_ continuation: CheckedContinuation<ProbeResult?, Never>) {
        box = Mutex(continuation)
    }

    func resume(_ value: ProbeResult?) {
        let continuation = box.withLock { stored -> CheckedContinuation<ProbeResult?, Never>? in
            defer { stored = nil }
            return stored
        }
        continuation?.resume(returning: value)
    }
}
