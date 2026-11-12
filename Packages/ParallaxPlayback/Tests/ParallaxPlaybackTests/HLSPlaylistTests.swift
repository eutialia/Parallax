import Foundation
import Testing
import ParallaxTestScaling
@testable import ParallaxPlayback

@Suite("HLSPlaylist", .scaledTimeLimit())
struct HLSPlaylistTests {

    @Test("the master playlist names the video rendition, its audio, and both codecs")
    func masterPlaylist() async throws {
        let plan = try await BridgePlan(reading: BridgeFixture.demuxer("h264-mkvmerge"))
        let master = HLSPlaylist.master(for: plan)

        // The file averages 618,880 bits per second, and no two-second stretch of it holds
        // twice that.
        let bandwidth = try #require(master.firstMatch(of: /BANDWIDTH=(\d+),/).flatMap { Int($0.1) })
        #expect((618_880...1_237_760).contains(bandwidth))
        #expect(master.replacing(/BANDWIDTH=\d+/, with: "BANDWIDTH=N") == """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Audio",DEFAULT=YES,AUTOSELECT=YES,URI="a.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=N,CODECS="avc1.640014,mp4a.40.2",RESOLUTION=160x90,FRAME-RATE=24.000,AUDIO="audio"
            v.m3u8

            """)
    }

    @Test("a media playlist lists the init segment and every segment with its length")
    func mediaPlaylist() async throws {
        let plan = try await BridgePlan(reading: BridgeFixture.demuxer("h264-mkvmerge"))

        #expect(HLSPlaylist.media(.audio, for: plan) == """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:3
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXT-X-MAP:URI="a-init.mp4"
            #EXTINF:2.000000,
            a-0.m4s
            #EXTINF:2.000000,
            a-1.m4s
            #EXTINF:2.000000,
            a-2.m4s
            #EXTINF:2.000000,
            a-3.m4s
            #EXTINF:2.000000,
            a-4.m4s
            #EXTINF:2.031000,
            a-5.m4s
            #EXT-X-ENDLIST

            """)
    }
}
