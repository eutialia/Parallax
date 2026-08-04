import Foundation
import Testing
import JellyfinAPI
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("DefaultJellyfinPlaybackClient — URL construction")
struct DefaultJellyfinPlaybackClientTests {
    private func client() -> DefaultJellyfinPlaybackClient {
        DefaultJellyfinPlaybackClient(
            session: JellyfinFixtures.session(
                id: "s1",
                token: "tok-1",
                serverURL: URL(string: "https://j.example.com")!,
                userID: "u1"
            ),
            identity: JellyfinFixtures.identity()
        )
    }

    @Test("Direct-play stream URL embeds api_key in the query")
    func directPlayURLHasAPIKey() {
        let url = client().streamURL(
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
        let url = client().transcodeURL(relativePath: "/videos/item-1/master.m3u8?api_key=tok-1&PlaySessionId=ps-1")
        #expect(url?.absoluteString.hasPrefix("https://j.example.com") == true)
        #expect(url?.absoluteString.contains("master.m3u8") == true)
        #expect(url?.query?.contains("api_key=tok-1") == true)
    }

    /// The sidecar fetch is client-side, so it needs api_key in the query AND absolute cue times —
    /// the in-manifest WebVTT offset drifts on fMP4 segments (jellyfin/jellyfin#16647). This is
    /// where that URL shape is proven; the resolve tests only prove the wiring to it.
    @Test("Subtitle sidecar URL carries copyTimestamps and api_key")
    func subtitleStreamURLShape() {
        let url = client().subtitleStreamURL(
            itemID: "item-1",
            mediaSourceID: "ms-1",
            streamIndex: 3,
            format: "vtt"
        )
        let absolute = url?.absoluteString ?? ""
        #expect(absolute.contains("/Videos/item-1/ms-1/Subtitles/3/Stream.vtt"))
        #expect(url?.query?.contains("api_key=tok-1") == true)
        #expect(url?.query?.lowercased().contains("copytimestamps=true") == true)
    }

    // MARK: - PlaybackInfo POST body

    /// One setup, one assertion per field. The stream-copy flags and the profile both live on the
    /// body because the server largely ignores this endpoint's query-param copies — without them
    /// an eligible source gets fully re-encoded.
    @Test(
        "The PlaybackInfo POST body carries the copy flags and the translated profile",
        arguments: [BodyField.videoStreamCopy, .audioStreamCopy, .maxStreamingBitrate]
    )
    func bodyFields(field: BodyField) {
        let capabilities = JellyfinFixtures.caps()
        let body = DefaultJellyfinPlaybackClient.playbackInfoBody(
            profile: DeviceProfileTranslator.deviceProfile(from: capabilities),
            startTimeTicks: nil,
            userID: "u1",
            selection: nil
        )
        switch field {
        case .videoStreamCopy:
            #expect(body.allowVideoStreamCopy == true)
        case .audioStreamCopy:
            #expect(body.allowAudioStreamCopy == true)
        case .maxStreamingBitrate:
            // Identity via a distinctive field rather than object equality — proves the exact
            // profile instance reached the body. The value is derived from the capabilities under
            // test, never a re-typed literal.
            #expect(body.deviceProfile?.maxStreamingBitrate == Int(capabilities.maxBitrate.rawValue))
        }
    }

    enum BodyField: Sendable {
        case videoStreamCopy, audioStreamCopy, maxStreamingBitrate
    }

    /// The media source id is the load-bearing part: Jellyfin only applies stream indices that
    /// arrive alongside the source they index into, and drops them silently otherwise — a switch
    /// sent without it looks accepted and rebuilds around the server's own defaults.
    @Test("Track indices and start time reach the body so a track switch rebuilds the transcode")
    func bodyCarriesTrackSelection() {
        let body = DefaultJellyfinPlaybackClient.playbackInfoBody(
            profile: DeviceProfileTranslator.deviceProfile(from: JellyfinFixtures.caps()),
            startTimeTicks: 6_000_000_000,
            userID: "u1",
            selection: StreamSelection(mediaSourceID: "ms-1", audioStreamIndex: 4, subtitleStreamIndex: 7)
        )
        #expect(body.mediaSourceID == "ms-1")
        #expect(body.audioStreamIndex == 4)
        #expect(body.subtitleStreamIndex == 7)
        #expect(body.startTimeTicks == 6_000_000_000)
        #expect(body.userID == "u1")
    }

    /// Burn-in paints the subtitle into the picture, which a copied video stream can't carry — so
    /// that one pick has to withdraw the stream-copy offer. Every other resolve keeps it (a copy
    /// preserves HDR and costs the server nothing).
    @Test(
        "Video stream copy is offered on every resolve except a burn-in subtitle pick",
        arguments: [
            (nil as StreamSelection?, true),
            (StreamSelection(mediaSourceID: "ms-1", audioStreamIndex: 4, subtitleStreamIndex: 1), true),
            (StreamSelection(mediaSourceID: "ms-1", audioStreamIndex: nil, subtitleStreamIndex: 7, burnsInSubtitle: true), false),
        ]
    )
    func bodyVideoStreamCopyFollowsBurnIn(selection: StreamSelection?, allowsCopy: Bool) {
        let body = DefaultJellyfinPlaybackClient.playbackInfoBody(
            profile: DeviceProfileTranslator.deviceProfile(from: JellyfinFixtures.caps()),
            startTimeTicks: nil,
            userID: "u1",
            selection: selection
        )
        #expect(body.allowVideoStreamCopy == allowsCopy)
        // Audio copy is orthogonal — burning a subtitle in never touches the audio stream.
        #expect(body.allowAudioStreamCopy == true)
    }

}

/// The SDK-backed playback client over a stubbed transport, so the endpoints, verbs and POST
/// bodies the server actually receives are pinned — the fake-client service tests can't see them.
@Suite("DefaultJellyfinPlaybackClient — wire contract")
struct DefaultJellyfinPlaybackClientWireTests {

    private func makeClient(
        stub: StubHTTPTransport,
        onTokenRejected: (@Sendable (ServerID) -> Void)? = nil
    ) -> DefaultJellyfinPlaybackClient {
        DefaultJellyfinPlaybackClient(
            session: JellyfinFixtures.session(id: "s1", token: "tok-1", serverURL: stub.baseURL, userID: "u1"),
            identity: JellyfinFixtures.identity(deviceID: "dev-1"),
            onTokenRejected: onTokenRejected,
            sessionConfiguration: stub.configuration
        )
    }

    @Test("playbackInfo POSTs to the item's PlaybackInfo endpoint with the selection in the query")
    func playbackInfoRequest() async throws {
        let stub = StubHTTPTransport()
        var response = PlaybackInfoResponse()
        response.playSessionID = "ps-1"
        var source = MediaSourceInfo()
        source.id = "ms-1"
        source.container = "mp4"
        response.mediaSources = [source]
        stub.always(.encoded(response))

        let decoded = try await makeClient(stub: stub).playbackInfo(
            itemID: "item-1",
            profile: DeviceProfileTranslator.deviceProfile(from: JellyfinFixtures.caps()),
            startTimeTicks: 120_000_000,
            selection: StreamSelection(mediaSourceID: "ms-1", audioStreamIndex: 2, subtitleStreamIndex: 3)
        )

        let request = try stub.onlyExchange()
        #expect(request.method == "POST")
        #expect(request.path == "/Items/item-1/PlaybackInfo")
        #expect(request.query("userId") == "u1")
        #expect(request.query("startTimeTicks") == "120000000")
        #expect(request.query("audioStreamIndex") == "2")
        #expect(request.query("subtitleStreamIndex") == "3")
        // Without this the server discards both indices above and rebuilds around its defaults.
        #expect(request.query("mediaSourceId") == "ms-1")
        // The body is authoritative for this endpoint — assert it on the wire, not only via the
        // pure builder.
        let body = try request.decodedBody(PlaybackInfoDto.self)
        #expect(body.allowVideoStreamCopy == true)
        #expect(body.allowAudioStreamCopy == true)
        #expect(body.deviceProfile?.maxStreamingBitrate == Int(JellyfinFixtures.caps().maxBitrate.rawValue))
        #expect(decoded.playSessionID == "ps-1")
        #expect(decoded.mediaSources?.first?.id == "ms-1")
    }

    @Test(
        "Each progress report POSTs to its own /Sessions/Playing path",
        arguments: [ReportKind.start, .progress, .stopped]
    )
    func progressReports(kind: ReportKind) async throws {
        let stub = StubHTTPTransport()
        stub.always(.noContent)
        let client = makeClient(stub: stub)

        let expectedPath: String
        switch kind {
        case .start:
            try await client.reportStart(PlaybackStateInfo(itemID: "item-1", positionTicks: 0))
            expectedPath = "/Sessions/Playing"
        case .progress:
            try await client.reportProgress(PlaybackStateInfo(itemID: "item-1", positionTicks: 42))
            expectedPath = "/Sessions/Playing/Progress"
        case .stopped:
            try await client.reportStopped(PlaybackStopInfo(itemID: "item-1", positionTicks: 99))
            expectedPath = "/Sessions/Playing/Stopped"
        }

        let request = try stub.onlyExchange()
        #expect(request.method == "POST")
        #expect(request.path == expectedPath)
        #expect(request.body?.isEmpty == false, "the report body carries the position the server records")
    }

    enum ReportKind: Sendable { case start, progress, stopped }

    /// The kill has to name BOTH the device and the play session — an unscoped delete would take
    /// down another device's job.
    @Test("stopEncoding deletes the device's active encoding for the play session")
    func stopEncoding() async throws {
        let stub = StubHTTPTransport()
        stub.always(.noContent)

        try await makeClient(stub: stub).stopEncoding(playSessionID: "ps-1")

        let request = try stub.onlyExchange()
        #expect(request.method == "DELETE")
        #expect(request.path == "/Videos/ActiveEncodings")
        #expect(request.query("deviceId") == "dev-1")
        #expect(request.query("playSessionId") == "ps-1")
    }

    @Test("pingSession posts the keepalive for the play session")
    func pingSession() async throws {
        let stub = StubHTTPTransport()
        stub.always(.noContent)

        try await makeClient(stub: stub).pingSession(playSessionID: "ps-1")

        let request = try stub.onlyExchange()
        #expect(request.method == "POST")
        #expect(request.path == "/Sessions/Playing/Ping")
        #expect(request.query("playSessionId") == "ps-1")
    }

    @Test("transcodingDelivery narrows /Sessions to this device and maps the running job")
    func transcodingDelivery() async throws {
        let stub = StubHTTPTransport()
        var info = TranscodingInfo()
        info.isVideoDirect = true
        info.audioCodec = "aac"
        var session = SessionInfoDto()
        session.deviceID = "dev-1"
        session.transcodingInfo = info
        stub.always(.encoded([session]))

        let delivery = try await makeClient(stub: stub).transcodingDelivery(playSessionID: "ps-1")

        let request = try stub.onlyExchange()
        #expect(request.path == "/Sessions")
        #expect(request.query("deviceId") == "dev-1")
        #expect(delivery?.isVideoDirect == true)
        #expect(delivery?.audioCodec == "aac")
    }

    @Test("currentUserConfiguration reads the signed-in user's configuration")
    func currentUserConfiguration() async throws {
        let stub = StubHTTPTransport()
        var user = UserDto()
        user.configuration = UserConfiguration(audioLanguagePreference: "fra")
        stub.always(.encoded(user))

        let configuration = try await makeClient(stub: stub).currentUserConfiguration()

        #expect(try stub.onlyExchange().path == "/Users/Me")
        #expect(configuration.audioLanguagePreference == "fra")
    }

    /// A configuration-less user would otherwise be "written back" as a fresh object, wiping every
    /// setting the whole-object endpoint replaces.
    @Test("A user payload with no configuration throws instead of yielding a blank one")
    func missingConfigurationThrows() async throws {
        let stub = StubHTTPTransport()
        stub.always(.encoded(UserDto()))
        await #expect(throws: AppError.self) {
            _ = try await makeClient(stub: stub).currentUserConfiguration()
        }
    }

    @Test("updateUserConfiguration posts the whole object for this user")
    func updateUserConfiguration() async throws {
        let stub = StubHTTPTransport()
        stub.always(.noContent)

        try await makeClient(stub: stub).updateUserConfiguration(
            UserConfiguration(audioLanguagePreference: "deu")
        )

        let request = try stub.onlyExchange()
        #expect(request.method == "POST")
        #expect(request.path == "/Users/Configuration")
        #expect(request.query("userId") == "u1")
        #expect(try request.decodedBody(UserConfiguration.self).audioLanguagePreference == "deu")
    }

    /// Playback shares the browse chokepoint: a token revoked mid-stream must report once,
    /// wherever it's noticed first.
    @Test("A 401 on a playback call reports the rejected token too")
    func unauthorizedReportsTokenRejection() async throws {
        let stub = StubHTTPTransport()
        stub.always(.json("{}", status: 401))
        let reported = ReportedServerIDs()
        let client = makeClient(stub: stub, onTokenRejected: { reported.record($0) })

        await #expect(throws: AppError.self) {
            try await client.pingSession(playSessionID: "ps-1")
        }
        #expect(reported.ids == [ServerID(rawValue: "s1")])
    }
}
