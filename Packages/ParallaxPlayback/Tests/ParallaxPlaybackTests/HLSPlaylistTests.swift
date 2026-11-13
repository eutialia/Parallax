import AVFoundation
import Foundation
import Testing
import ParallaxTestScaling
@testable import ParallaxPlayback

@Suite("HLSPlaylist", .scaledTimeLimit())
struct HLSPlaylistTests {

    @Test("the master playlist names the video rendition, each audio track, and every codec")
    func masterPlaylist() async throws {
        let plan = try await BridgePlan(reading: BridgeFixture.demuxer("h264-mkvmerge"), support: BridgeFixture.everyDecoder, showsHDR: true)
        let master = HLSPlaylist.master(for: plan)

        // The file averages 618,880 bits per second, and no two-second stretch of it holds
        // twice that.
        let bandwidth = try #require(master.firstMatch(of: /BANDWIDTH=(\d+),/).flatMap { Int($0.1) })
        #expect((618_880...1_237_760).contains(bandwidth))
        #expect(master.replacing(/BANDWIDTH=\d+/, with: "BANDWIDTH=N") == """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Audio 1",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2",URI="a0.m3u8"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Audio 2",DEFAULT=NO,AUTOSELECT=NO,CHANNELS="2",URI="a1.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=N,CODECS="avc1.640014,mp4a.40.2,ac-3",RESOLUTION=160x90,FRAME-RATE=24.000,VIDEO-RANGE=SDR,AUDIO="audio"
            v.m3u8

            """)
    }

    @Test("an audio track is named by its title, else its language in the viewer's own, whichever code the file spells it with")
    func audioTrackNames() async throws {
        // Untitled English, "Surround" in Japanese marked as the default, and untitled "ger".
        let plan = try await BridgePlan(reading: BridgeFixture.demuxer("four-audio-tracks"), support: BridgeFixture.everyDecoder, showsHDR: true)
        func audioLines(_ locale: String) -> [String] {
            HLSPlaylist.master(for: plan, locale: Locale(identifier: locale))
                .split(separator: "\n").filter { $0.hasPrefix("#EXT-X-MEDIA") }.map(String.init)
        }

        #expect(audioLines("en_US") == [
            #"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",LANGUAGE="eng",DEFAULT=NO,AUTOSELECT=NO,CHANNELS="2",URI="a0.m3u8""#,
            #"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Surround",LANGUAGE="jpn",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="6",URI="a1.m3u8""#,
            #"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="German",LANGUAGE="ger",DEFAULT=NO,AUTOSELECT=NO,CHANNELS="2",URI="a2.m3u8""#,
        ])
        #expect(audioLines("ja_JP").map { $0.firstMatch(of: /NAME="([^"]*)"/)?.1 } == ["英語", "Surround", "ドイツ語"])
    }

    @Test("a repeated track name gets a number no other track's name already has", arguments: [
        (["English", "English", "Japanese", "English"], ["English", "English 2", "Japanese", "English 3"]),
        (["Commentary", "Commentary", "Commentary 2"], ["Commentary", "Commentary 3", "Commentary 2"]),
        (["English", "English 2", "English"], ["English", "English 2", "English 3"]),
    ])
    func repeatedNamesAreNumbered(names: [String], distinct: [String]) {
        #expect(HLSPlaylist.distinct(names) == distinct)
    }

    @Test("the master playlist declares the video's transfer function", arguments: [
        ("hdr-pq", "PQ"), ("hdr-hlg", "HLG"), ("frame-numbers-hevc", "SDR"),
    ])
    func videoRange(name: String, range: String) async throws {
        let plan = try await BridgePlan(reading: BridgeFixture.demuxer(name), support: BridgeFixture.everyDecoder, showsHDR: true)
        #expect(HLSPlaylist.master(for: plan).firstMatch(of: /VIDEO-RANGE=([A-Z]+),/)?.1 == range[...])
    }

    @Test("Dolby Vision 8.1 and 8.4 are named over their HEVC base and carry their record, and 8.2 carries neither", arguments: [
        ("dolby-vision-8-1", "dvh1.08.01/db1p" as String?, "PQ"), ("dolby-vision-8-4", "dvh1.08.01/db4h", "HLG"),
        ("dolby-vision-8-2", nil, "SDR"),
    ])
    func dolbyVisionProfile8(name: String, supplemental: String?, range: String) async throws {
        let plan = try await BridgePlan(reading: BridgeFixture.demuxer(name), support: BridgeFixture.everyDecoder, showsHDR: true)
        let master = HLSPlaylist.master(for: plan)
        #expect(master.firstMatch(of: /SUPPLEMENTAL-CODECS="([^"]+)"/).map { String($0.1) } == supplemental)
        #expect(master.firstMatch(of: /VIDEO-RANGE=([A-Z]+),/)?.1 == range[...])

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        try plan.video.initSegment.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        let atoms = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
        #expect((atoms?["dvvC"] != nil) == (supplemental != nil), "\(atoms?.keys.sorted() ?? [])")
    }

    @Test("a media playlist lists the init segment and every segment with its length")
    func mediaPlaylist() async throws {
        let plan = try await BridgePlan(reading: BridgeFixture.demuxer("h264-mkvmerge"), support: BridgeFixture.everyDecoder, showsHDR: true)

        #expect(HLSPlaylist.media(.audio(0), of: plan.audio[0]) == """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:3
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXT-X-MAP:URI="a0-init.mp4"
            #EXTINF:2.000000,
            a0-0.m4s
            #EXTINF:2.000000,
            a0-1.m4s
            #EXTINF:2.000000,
            a0-2.m4s
            #EXTINF:2.000000,
            a0-3.m4s
            #EXTINF:2.000000,
            a0-4.m4s
            #EXTINF:2.031000,
            a0-5.m4s
            #EXT-X-ENDLIST

            """)
    }
}
