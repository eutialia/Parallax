import Foundation
import ParallaxCore
import ParallaxFileBrowse
import ParallaxPlayback

/// One SMB file being delivered to AVPlayer or the thumbnailer: the pooled reader and the
/// delivery reading through it. The reader is this type's from `start` on, whatever happens;
/// no caller releases it.
nonisolated struct SMBDelivery: Sendable {
    private let reader: any SMBShareReading
    private let delivery: MediaDelivery

    var url: URL { delivery.url }

    /// The probe gave no verdict on the file. `transportFault` is whether the link, not the
    /// file, is to blame.
    enum ProbeFailure: Error {
        case timedOut(transportFault: Bool)
        case unreadable(any Error, transportFault: Bool)
    }

    static func start(
        reader: any SMBShareReading,
        fileName: String,
        support: AVPlayerSupport,
        bridging: Bool = true,
        scope: LocalMediaServer.AddressScope = .lan,
        probeDeadline: Duration = MediaDelivery.defaultProbeDeadline,
        clock: any Clock<Duration>
    ) async throws -> SMBDelivery {
        do {
            let delivery = try await MediaDelivery.start(
                reading: reader, fileName: fileName, support: support, bridging: bridging, scope: scope,
                probeDeadline: probeDeadline, clock: clock)
            return SMBDelivery(reader: reader, delivery: delivery)
        } catch MediaDelivery.ProbeFailure.timedOut {
            // The reader may sit in a native read until its socket timeout, and a drain would
            // wait behind it. This teardown does not wait: it condemns the borrow.
            throw ProbeFailure.timedOut(transportFault: await reader.teardownCapturingTransportFault())
        } catch MediaDelivery.ProbeFailure.unreadable(let underlying) {
            let transportFault = await reader.hadTransportFault
            await reader.drainAndDisconnect()
            throw ProbeFailure.unreadable(underlying, transportFault: transportFault)
        } catch {
            await reader.drainAndDisconnect()
            throw error
        }
    }

    /// Idempotent. The server stops first and the reader drains second: draining first would
    /// hand a live serve loop a connection already checked back into the pool. The drain is
    /// bounded and awaited, so the caller's next fetch cannot overlap it.
    ///
    /// - Parameter discardingConnection: the connection is dropped instead of returning to the
    ///   pool. An hours-long playback socket may be silently degraded: stalls surface as short
    ///   reads, never a thrown error, so the pool's taint rule cannot catch them.
    func stop(discardingConnection: Bool = false) async {
        await delivery.stop()
        if discardingConnection { await reader.markUnreusable() }
        await reader.drainAndDisconnect()
    }

    var stats: LocalMediaServer.Stats {
        get async { await delivery.stats }
    }

    /// A transport fault means the file may be fine and the network blipped, so a failed
    /// frame-grab must not blame the file for it.
    var hadTransportFault: Bool {
        get async { await reader.hadTransportFault }
    }
}
