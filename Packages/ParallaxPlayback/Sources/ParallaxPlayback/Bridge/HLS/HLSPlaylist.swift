import Foundation
import ParallaxCore

/// The resources of a bridged file, and the paths AVPlayer asks for them by.
enum BridgeResource: Equatable, Sendable {
    case master
    case playlist(RenditionID)
    case initSegment(RenditionID)
    case mediaSegment(RenditionID, Int)

    var path: String {
        switch self {
        case .master: "master.m3u8"
        case .playlist(let id): "\(Self.name(of: id)).m3u8"
        case .initSegment(let id): "\(Self.name(of: id))-init.mp4"
        case .mediaSegment(let id, let index): "\(Self.name(of: id))-\(index).m4s"
        }
    }

    /// "v" for the video, "a0" for the first audio track.
    private static func name(of id: RenditionID) -> String {
        switch id {
        case .video: "v"
        case .audio(let place): "a\(place)"
        }
    }

    private static func rendition(named name: Substring) -> RenditionID? {
        if name == "v" { return .video }
        return name.first == "a" ? Int(name.dropFirst()).flatMap { $0 >= 0 ? .audio($0) : nil } : nil
    }

    init?(path: String) {
        if path == Self.master.path {
            self = .master
            return
        }
        let name = path.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let parts = name[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard name.count == 2, let id = Self.rendition(named: parts[0]) else { return nil }
        let candidate: Self? = switch (parts.count, name[1]) {
        case (1, "m3u8"): .playlist(id)
        case (2, "mp4") where parts[1] == "init": .initSegment(id)
        case (2, "m4s"): Int(parts[1]).flatMap { $0 >= 0 ? .mediaSegment(id, $0) : nil }
        default: nil
        }
        // Only the one spelling this type writes is a resource: "v-007.m4s" is not "v-7.m4s",
        // and "a00.m3u8" is not "a0.m3u8".
        guard let candidate, candidate.path == path else { return nil }
        self = candidate
    }
}

/// The HLS playlists of a `BridgePlan`. They come from the plan alone: no media is read.
enum HLSPlaylist {
    static let mediaType = "application/vnd.apple.mpegurl"

    /// Every audio track is in one group, whatever its codec, so the viewer can switch between
    /// all of them. A track with no title is named in the device's language.
    static func master(for plan: BridgePlan) -> String {
        let video = plan.video.rendition
        let size = video.parameters.pixelSize
        let codecs = ([video.codec] + plan.audio.map(\.rendition.codec))
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ",")
        let frameRate = video.frameRate.map {
            ",FRAME-RATE=" + String(format: "%.3f", Double($0.numerator) / Double($0.denominator))
        } ?? ""
        let dolbyVision = video.supplementalCodec.map { ",SUPPLEMENTAL-CODECS=\"\($0)\"" } ?? ""
        let names = audioNames(for: plan)
        let audio = plan.audio.indices.map { place in
            let rendition = plan.audio[place].rendition
            let language = rendition.stream.language.map { ",LANGUAGE=\"\(quotable($0))\"" } ?? ""
            let isDefault = place == plan.defaultAudio ? "YES" : "NO"
            return "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"\(names[place])\"\(language)"
                + ",DEFAULT=\(isDefault),AUTOSELECT=\(isDefault),CHANNELS=\"\(rendition.parameters.playlistChannels)\""
                + ",URI=\"\(BridgeResource.playlist(.audio(place)).path)\"\n"
        }
        return """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-INDEPENDENT-SEGMENTS
            \(audio.joined())#EXT-X-STREAM-INF:BANDWIDTH=\(plan.peakBitrate),CODECS="\(codecs)"\(dolbyVision),RESOLUTION=\(size.width)x\(size.height)\(frameRate),VIDEO-RANGE=\(video.parameters.videoRange)\(audio.isEmpty ? "" : ",AUDIO=\"audio\"")
            \(BridgeResource.playlist(.video).path)

            """
    }

    /// What the track menu shows for each audio track: the file's title for it, else its
    /// language, else its place.
    private static func audioNames(for plan: BridgePlan) -> [String] {
        distinct(plan.audio.indices.map { place in
            let stream = plan.audio[place].rendition.stream
            return quotable(
                stream.title ?? TrackDisplay.languageName(stream.language) ?? "Audio \(place + 1)")
        })
    }

    /// `names` with each repeat given the lowest number that makes it unlike every other name:
    /// a group's names have to differ.
    static func distinct(_ names: [String]) -> [String] {
        names.indices.reduce(into: [String]()) { taken, place in
            let name = names[place]
            let isFree = { (candidate: String) in !taken.contains(candidate) && !names[(place + 1)...].contains(candidate) }
            taken.append(
                taken.contains(name) ? (2...).lazy.map { "\(name) \($0)" }.first(where: isFree) ?? name : name)
        }
    }

    /// A playlist's quoted string cannot hold a quote or a line break.
    private static func quotable(_ text: String) -> String {
        String(text.map { $0 == "\"" ? "'" : $0.isNewline ? " " : $0 })
    }

    static func media(_ id: RenditionID, of track: BridgePlan.Track) -> String {
        let segments = track.segments
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
