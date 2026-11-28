import Foundation
import ParallaxCore
import ParallaxFileBrowse
import ParallaxPlayback
import ParallaxSubtitles

/// One SMB file being delivered to AVPlayer: the pooled reader and the
/// delivery reading through it. The reader is this type's from `start` on, whatever happens;
/// no caller releases it.
nonisolated struct SMBDelivery: Sendable {
    private let reader: any SMBShareReading
    private let delivery: MediaDelivery

    var url: URL { delivery.url }

    /// The text subtitles stored in the file, each with the lines the delivery reads out of it.
    var subtitles: [FileSubtitle] {
        delivery.subtitles.map { subtitle in
            let (format, lineFormat): (FileSubtitle.Format, SubtitleLineFormat) = switch subtitle.format {
            case .ass(let header): (.ass, .ass(header: header))
            case .srt: (.srt, .srt)
            }
            return FileSubtitle(
                stream: subtitle.id, format: format, title: subtitle.title, language: subtitle.language,
                isForced: subtitle.isForced, isHearingImpaired: subtitle.isHearingImpaired,
                lines: SubtitleLineStream(format: lineFormat) { [delivery] in
                    let read = delivery.lines(of: subtitle.id)
                    return AsyncStream { continuation in
                        let forwarding = Task {
                            for await lines in read {
                                continuation.yield(lines.map {
                                    SubtitleLine(start: $0.start, duration: $0.duration, content: $0.content)
                                })
                            }
                            continuation.finish()
                        }
                        continuation.onTermination = { _ in forwarding.cancel() }
                    }
                })
        }
    }

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
        showsHDR: Bool = true,
        clock: any Clock<Duration>
    ) async throws -> SMBDelivery {
        do {
            let delivery = try await MediaDelivery.start(
                reading: reader, fileName: fileName, support: support, showsHDR: showsHDR,
                clock: clock)
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
    ///   pool. An hours-long playback socket may be degraded without a read ever throwing, so
    ///   the pool's taint rule cannot catch it.
    func stop(discardingConnection: Bool = false) async {
        await delivery.stop()
        if discardingConnection { await reader.markUnreusable() }
        await reader.drainAndDisconnect()
    }
}
