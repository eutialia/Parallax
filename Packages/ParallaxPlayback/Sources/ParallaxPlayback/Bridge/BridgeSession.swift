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
    static func open(_ reader: any RandomAccessReading) async throws -> BridgeSession {
        do {
            let demuxer = try await MediaDemuxer.open(reader)
            return BridgeSession(demuxer: demuxer, plan: try await BridgePlan(reading: demuxer))
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
            return .init(Data(HLSPlaylist.media(id, for: plan).utf8), contentType: HLSPlaylist.mediaType)
        case .initSegment(let id):
            return .init(plan.track(id).initSegment, contentType: "video/mp4")
        case .mediaSegment(let id, let index):
            let track = plan.track(id)
            guard track.segments.indices.contains(index) else { return nil }
            let segment = track.segments[index]
            let rendition = track.rendition
            let packets = try await demuxer.packets(from: segment.entries.lowerBound, to: segment.entries.upperBound)
                .filter { $0.stream == rendition.stream.index }
            return .init(
                try SegmentWriter.mediaSegment(
                    for: rendition, packets: packets, lastingUntil: id == .audio ? segment.end : nil),
                contentType: "video/mp4")
        }
    }
}
