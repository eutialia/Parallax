import Foundation
import Testing
import JellyfinAPI
@testable import ParallaxJellyfin

@Suite("DefaultJellyfinPlaybackClient — URL construction")
struct DefaultJellyfinPlaybackClientTests {
    private func sampleSession() -> Session {
        let data = JellyfinServerData(
            serverURL: URL(string: "https://j.example.com")!,
            serverName: "Home",
            user: UserSnapshot(id: "u1", name: "alice", serverLastUpdatedAt: nil)
        )
        return Session(id: ServerID(rawValue: "s1"), data: data, accessToken: "tok-1")
    }

    private func identity() -> DeviceIdentity {
        DeviceIdentity(client: "Parallax", deviceName: "Tester", deviceID: "dev-1", version: "1.0")
    }

    @Test("Direct-play stream URL embeds api_key in the query")
    func directPlayURLHasAPIKey() {
        let client = DefaultJellyfinPlaybackClient(session: sampleSession(), identity: identity())
        let url = client.streamURL(
            StreamRequest(
                itemID: "item-1",
                container: "mp4",
                mediaSourceID: "ms-1",
                playSessionID: "ps-1",
                startTimeTicks: 0,
                isStatic: true
            )
        )
        let query = url?.query ?? ""
        #expect(url?.absoluteString.contains("/Videos/item-1/stream.mp4") == true)
        #expect(query.contains("api_key=tok-1"))
        #expect(query.contains("mediaSourceId=ms-1") || query.contains("MediaSourceId=ms-1"))
    }

    @Test("Server transcodingURL is resolved against the server and kept intact")
    func transcodeURLResolved() {
        let client = DefaultJellyfinPlaybackClient(session: sampleSession(), identity: identity())
        let url = client.transcodeURL(relativePath: "/videos/item-1/master.m3u8?api_key=tok-1&PlaySessionId=ps-1")
        #expect(url?.absoluteString.hasPrefix("https://j.example.com") == true)
        #expect(url?.absoluteString.contains("master.m3u8") == true)
        #expect(url?.query?.contains("api_key=tok-1") == true)
    }
}
