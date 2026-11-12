import Foundation

/// The resources of a bridged file, and the paths AVPlayer asks for them by.
enum BridgeResource: Equatable, Sendable {
    case master
    case playlist(RenditionID)
    case initSegment(RenditionID)
    case mediaSegment(RenditionID, Int)

    var path: String {
        switch self {
        case .master: "master.m3u8"
        case .playlist(let id): "\(id.rawValue).m3u8"
        case .initSegment(let id): "\(id.rawValue)-init.mp4"
        case .mediaSegment(let id, let index): "\(id.rawValue)-\(index).m4s"
        }
    }

    init?(path: String) {
        if path == Self.master.path {
            self = .master
            return
        }
        let name = path.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let parts = name[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard name.count == 2, let id = RenditionID(rawValue: String(parts[0])) else { return nil }
        let candidate: Self? = switch (parts.count, name[1]) {
        case (1, "m3u8"): .playlist(id)
        case (2, "mp4") where parts[1] == "init": .initSegment(id)
        case (2, "m4s"): Int(parts[1]).flatMap { $0 >= 0 ? .mediaSegment(id, $0) : nil }
        default: nil
        }
        // Only the one spelling this type writes is a resource: "v-007.m4s" is not "v-7.m4s".
        guard let candidate, candidate.path == path else { return nil }
        self = candidate
    }
}

/// The HLS playlists of a `BridgePlan`. They come from the plan alone: no media is read.
enum HLSPlaylist {
    static let mediaType = "application/vnd.apple.mpegurl"

    static func master(for plan: BridgePlan) -> String {
        let video = plan.video.rendition.stream
        let size = video.parameters.pixelSize
        let codecs = "\(plan.video.rendition.codec),\(plan.audio.rendition.codec)"
        let frameRate = video.frameRate.map {
            ",FRAME-RATE=" + String(format: "%.3f", Double($0.numerator) / Double($0.denominator))
        } ?? ""
        return """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Audio",DEFAULT=YES,AUTOSELECT=YES,URI="\(BridgeResource.playlist(.audio).path)"
            #EXT-X-STREAM-INF:BANDWIDTH=\(plan.peakBitrate),CODECS="\(codecs)",RESOLUTION=\(size.width)x\(size.height)\(frameRate),AUDIO="audio"
            \(BridgeResource.playlist(.video).path)

            """
    }

    static func media(_ id: RenditionID, for plan: BridgePlan) -> String {
        let segments = plan.track(id).segments
        let longest = segments.map(\.seconds).max() ?? 0
        let head = """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:\(Int(longest.rounded(.up)))
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXT-X-MAP:URI="\(BridgeResource.initSegment(id).path)"

            """
        let body = segments.indices.map { index in
            "#EXTINF:\(String(format: "%.6f", segments[index].seconds)),\n\(BridgeResource.mediaSegment(id, index).path)\n"
        }
        return head + body.joined() + "#EXT-X-ENDLIST\n"
    }
}
