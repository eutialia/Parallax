import Foundation
import ParallaxCore

/// Serves one bridged file: playlists from the plan, and each segment built from the file when
/// it is asked for. It keeps nothing between requests, so the same path always gives the same
/// bytes, in whatever order AVPlayer asks.
struct BridgeSession: MediaResponder {
    let demuxer: MediaDemuxer
    let plan: BridgePlan

    /// Reads the file's headers, index and first segment. Throws a `BridgeRefusal` for a file
    /// the bridge cannot deliver, and the reader's own error when a read fails.
    static func open(
        _ reader: any RandomAccessReading, support: AVPlayerSupport, showsHDR: Bool
    ) async throws -> BridgeSession {
        do {
            let demuxer = try await MediaDemuxer.open(reader)
            let plan = try await BridgePlan(reading: demuxer, support: support, showsHDR: showsHDR)
            if !plan.omittedAudio.isEmpty {
                Log.playback.info("bridge: audio left out: \(plan.omittedAudio.joined(separator: ", "), privacy: .public)")
            }
            return BridgeSession(demuxer: demuxer, plan: plan)
        } catch let failure
            where failure is MediaDemuxer.OpenFailure || failure is MediaDemuxer.ReadFailure
            || failure is SegmentWriter.Failure {
            throw BridgeRefusal.unreadable(detail: "\(failure)")
        }
    }

    var entryPath: String { BridgeResource.master.path }

    func resource(at path: String) async throws -> ServedResource? {
        guard let resource = BridgeResource(path: path) else { return nil }
        switch resource {
        case .master:
            return .init(Data(HLSPlaylist.master(for: plan).utf8), contentType: HLSPlaylist.mediaType)
        case .playlist(let id):
            return plan.track(id).map {
                .init(Data(HLSPlaylist.media(id, of: $0).utf8), contentType: HLSPlaylist.mediaType)
            }
        case .initSegment(let id):
            return plan.track(id).map { .init($0.initSegment, contentType: "video/mp4") }
        case .mediaSegment(let id, let index):
            guard let track = plan.track(id), track.segments.indices.contains(index) else { return nil }
            let segment = track.segments[index]
            let rendition = track.rendition
            let packets = try await demuxer.packets(
                from: segment.entries.lowerBound, to: segment.entries.upperBound,
                takingLaterAudio: id != .video && index == track.segments.count - 1
            ).filter { $0.stream == rendition.stream.index }
            return .init(
                try SegmentWriter.mediaSegment(
                    for: rendition, packets: packets, lastingUntil: id == .video ? nil : segment.end),
                contentType: "video/mp4")
        }
    }
}
