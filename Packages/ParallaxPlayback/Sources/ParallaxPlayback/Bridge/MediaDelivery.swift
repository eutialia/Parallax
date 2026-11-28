import Foundation
import ParallaxCore
import Synchronization

/// A file on its way to AVPlayer: the URL to load, and the server behind it.
public struct MediaDelivery: Sendable {
    public let url: URL
    private let server: LocalMediaServer
    private let bridge: BridgeSession?
    private let clock: any Clock<Duration>

    private static let probeDeadline: Duration = .seconds(4)

    /// The text subtitle streams stored in the file, in file order. Empty for a file AVPlayer
    /// opens itself, whose subtitles it lists as its own.
    public var subtitles: [EmbeddedSubtitle] { bridge?.subtitles ?? [] }

    /// The lines of one of `subtitles` read so far, in time order, then each line as the bridge
    /// first reads it. The bridge reads a line when AVPlayer fetches the pictures stored beside
    /// it, so a line that starts before a seek's target is not read until playback passes back
    /// over it. Ends when the delivery stops.
    public func lines(of subtitle: EmbeddedSubtitle.ID) -> AsyncStream<[EmbeddedSubtitleLine]> {
        guard let bridge else { return AsyncStream { $0.finish() } }
        return bridge.subtitleLines.lines(of: subtitle, from: bridge.plan.start)
    }

    /// Reading the file produced no verdict, so nothing is known about its format.
    public enum ProbeFailure: Error {
        case timedOut
        /// The reader's own error, for the caller that knows how to classify it.
        case unreadable(any Error)
    }

    /// Reads what it must of `reader` under `probeDeadline`, picks the route, and starts the
    /// server for it. A file AVPlayer opens is served as it is. A file in one of
    /// `bridgedContainers`, or an MP4 or MOV AVPlayer would not play as stored, goes through
    /// the bridge, which costs its keyframe list and its opening. A file with no index has its keyframes listed by reading
    /// it, and the deadline abandons that read only when it has passed with no packet read.
    /// `showsHDR` is whether AVPlayer shows HDR on this device now: the bridge refuses PQ video
    /// where it does not.
    ///
    /// Throws the `Unplayable` reason when the file cannot reach AVPlayer, a `ProbeFailure`
    /// when reading gave no verdict, or the server's own error when it cannot bind. The
    /// reader stays the caller's on every path: this never disconnects it.
    public static func start(
        reading reader: any RandomAccessReading,
        fileName: String,
        support: AVPlayerSupport,
        showsHDR: Bool = true,
        clock: any Clock<Duration>
    ) async throws -> MediaDelivery {
        let progress = ListingProgress()
        let routed = await race(against: probeDeadline, on: clock, restartedBy: progress) {
            try await responder(
                reading: reader, fileName: fileName, support: support, showsHDR: showsHDR,
                progress: progress, clock: clock)
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
        let server = LocalMediaServer(responder: responder, clock: clock)
        do {
            return MediaDelivery(
                url: try await server.start(), server: server, bridge: responder as? BridgeSession,
                clock: clock)
        } catch {
            await server.stop()
            throw error
        }
    }

    /// How long after an open starts a large file with no index is still sampled for more
    /// keyframes than it needs. Past it, sampling goes on only where a segment would be too
    /// large to hold.
    static let samplingTime: Duration = .milliseconds(2500)

    /// The containers AVPlayer cannot open that the bridge opens. It reads Matroska, transport
    /// streams, FLV, AVI, ASF and program streams in spans.
    static let bridgedContainers: Set<Container> = [.mkv, .ts, .flv, .avi, .asf, .mpegps]

    /// Whether the bridge opens a file AVPlayer cannot play for `reason`: one in a container only
    /// the bridge reads, or an MP4 or MOV with a stream AVPlayer would not decode or show as
    /// stored. The probe reads codecs, profiles and hazards from MP4 and MOV only.
    private static func bridges(_ reason: Unplayable) -> Bool {
        switch reason {
        case .container(let container?): bridgedContainers.contains(container)
        case .videoCodec, .audioCodec, .undecodedProfile: true
        case .directHazards: true
        case .incompleteFile, .container(nil), .refused: false
        }
    }

    /// The hazards the bridge plays through. It copies a stream's configuration record and its
    /// times as they are stored: a record with no parameter sets plays no picture, and show
    /// times that follow decode order show the pictures in it. Its one init segment holds one
    /// sample description.
    private static let mendedHazards: Set<AVPlayerHazard> = [.inBandParameterSets, .interlacedVideo]

    /// What serves the file. Throws an `Unplayable`, or the reader's own error.
    private static func responder(
        reading reader: any RandomAccessReading, fileName: String, support: AVPlayerSupport, showsHDR: Bool,
        progress: ListingProgress, clock: some Clock<Duration>
    ) async throws -> any MediaResponder {
        let probe = try await MediaProbe.probe(reader)
        let unmended = probe.avPlayerHazards.subtracting(mendedHazards)
        switch DirectPlay.verdict(for: probe, support: support) {
        // The bridge copies a stream as it is stored, so it would carry the hazard to AVPlayer.
        case .unplayable where !unmended.isEmpty:
            throw Unplayable.directHazards(unmended)
        case .unplayable(let reason) where bridges(reason):
            do {
                let opening = clock.now
                let samplingEnd = opening.advanced(by: samplingTime)
                let session = try await BridgeSession.open(
                    reader, support: support, showsHDR: showsHDR,
                    listing: KeyframeListing(progress: progress) { clock.now >= samplingEnd }, clock: clock)
                let milliseconds = Int((opening.duration(to: clock.now) / .milliseconds(1)).rounded())
                BridgeReport.log.notice(
                    "bridge: opened in \(milliseconds) ms, \(session.keyframes.count) keyframes, "
                        + "\(session.report(of: []).bytesFetched >> 10) KB read")
                return session
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
    ///
    /// A bridged delivery then writes what it cost, once its segment reads have returned. A read
    /// parked in a stuck source read is left to the reader's release after 2 s.
    public func stop() async {
        await server.stop()
        bridge?.subtitleLines.finish()
        guard let bridge, bridge.reads.stop() else { return }
        _ = await Self.race(against: .seconds(2), on: clock) { await bridge.reads.allReturned() }
        let report = bridge.report(of: await server.records)
        BridgeReport.log.notice("\(report)")
    }

    /// Races `work` against `deadline`, abandoning the work if the deadline wins. Nil on
    /// timeout. A deadline that passes with `listing` further on than when it started starts
    /// again.
    ///
    /// Unstructured on purpose: a task group would await the child even after `cancelAll()`,
    /// so a wedged source stalls the caller until the source's own socket timeout. Abandoned
    /// work ends when its read returns and holds only memory.
    private static func race<Value: Sendable>(
        against deadline: Duration, on clock: any Clock<Duration>, restartedBy listing: ListingProgress? = nil,
        _ work: @escaping @Sendable () async throws -> Value
    ) async -> Result<Value, any Error>? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<Value, any Error>?, Never>) in
            let latch = OneShotLatch(continuation)
            let working = Task { () -> Result<Value, any Error> in
                do { return .success(try await work()) } catch { return .failure(error) }
            }
            let timer = Task {
                var seen = listing?.packetsRead
                while (try? await clock.sleep(for: deadline)) != nil {
                    let read = listing?.packetsRead
                    guard let read, read != seen else {
                        working.cancel()          // cooperative only: a wedged read ignores it
                        latch.resume(nil)
                        return
                    }
                    seen = read
                }
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
