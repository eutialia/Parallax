import Foundation
import Testing
import JellyfinAPI
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("TranscodeDelivery — session mapping")
struct TranscodeDeliveryMappingTests {
    private func transcodingInfo(
        isVideoDirect: Bool?,
        isAudioDirect: Bool?,
        reasons: [TranscodeReason] = []
    ) -> TranscodingInfo {
        TranscodingInfo(
            audioCodec: "aac",
            bitrate: 8_000_000,
            isAudioDirect: isAudioDirect,
            isVideoDirect: isVideoDirect,
            transcodeReasons: reasons.isEmpty ? nil : reasons,
            videoCodec: "hevc"
        )
    }

    private func session(deviceID: String?, transcodingInfo: TranscodingInfo?) -> SessionInfoDto {
        var session = SessionInfoDto()
        session.deviceID = deviceID
        session.transcodingInfo = transcodingInfo
        return session
    }

    @Test("A video-copy session maps to isVideoDirect == true with codecs and reasons")
    func videoCopySessionMaps() {
        let sessions = [
            session(
                deviceID: "dev-1",
                transcodingInfo: transcodingInfo(
                    isVideoDirect: true,
                    isAudioDirect: false,
                    reasons: [.audioCodecNotSupported, .containerNotSupported]
                )
            )
        ]
        let delivery = DefaultJellyfinPlaybackClient.delivery(fromSessions: sessions, deviceID: "dev-1")
        #expect(delivery == TranscodeDelivery(
            isVideoDirect: true,
            isAudioDirect: false,
            videoCodec: "hevc",
            audioCodec: "aac",
            transcodeReasons: [
                TranscodeReason.audioCodecNotSupported.rawValue,
                TranscodeReason.containerNotSupported.rawValue,
            ]
        ))
    }

    /// The nil arm is the load-bearing one: a server that simply didn't report a flag must never be
    /// read as "it copied the bitstream", or the debug overlay would claim a remux that isn't
    /// happening.
    @Test(
        "Server direct flags map through, and an unreported flag reads as false",
        arguments: [
            (true as Bool?, false as Bool?, true, false),
            (false, false, false, false),
            (nil, nil, false, false),
            (nil, true, false, true),
        ] as [(Bool?, Bool?, Bool, Bool)]
    )
    func directFlagMapping(
        reportedVideo: Bool?,
        reportedAudio: Bool?,
        expectedVideo: Bool,
        expectedAudio: Bool
    ) {
        let sessions = [
            session(
                deviceID: "dev-1",
                transcodingInfo: transcodingInfo(isVideoDirect: reportedVideo, isAudioDirect: reportedAudio)
            )
        ]
        let delivery = DefaultJellyfinPlaybackClient.delivery(fromSessions: sessions, deviceID: "dev-1")
        #expect(delivery?.isVideoDirect == expectedVideo)
        #expect(delivery?.isAudioDirect == expectedAudio)
        #expect(delivery?.transcodeReasons == [])
    }

    @Test("A session without transcodingInfo yields nil (ffmpeg not started / direct play)")
    func absentTranscodingInfoIsNil() {
        let sessions = [session(deviceID: "dev-1", transcodingInfo: nil)]
        let delivery = DefaultJellyfinPlaybackClient.delivery(fromSessions: sessions, deviceID: "dev-1")
        #expect(delivery == nil)
    }

    @Test("Another device's transcoding session is filtered out")
    func wrongDeviceFilteredOut() {
        let sessions = [
            session(
                deviceID: "someone-else",
                transcodingInfo: transcodingInfo(isVideoDirect: true, isAudioDirect: true)
            )
        ]
        let delivery = DefaultJellyfinPlaybackClient.delivery(fromSessions: sessions, deviceID: "dev-1")
        #expect(delivery == nil)
    }

    @Test("Among mixed sessions, ours with transcodingInfo wins over idle and foreign ones")
    func mixedListPicksOurTranscodingSession() {
        let sessions = [
            session(deviceID: "someone-else", transcodingInfo: transcodingInfo(isVideoDirect: false, isAudioDirect: false)),
            session(deviceID: "dev-1", transcodingInfo: nil),
            session(deviceID: "dev-1", transcodingInfo: transcodingInfo(isVideoDirect: true, isAudioDirect: true)),
        ]
        let delivery = DefaultJellyfinPlaybackClient.delivery(fromSessions: sessions, deviceID: "dev-1")
        #expect(delivery?.isVideoDirect == true)
        #expect(delivery?.isAudioDirect == true)
    }
}

@Suite("PlaybackInfoService — transcodingDelivery pass-through")
struct PlaybackInfoServiceTranscodingDeliveryTests {
    @Test("Forwards the playSessionID and returns the client's delivery")
    func passThrough() async {
        let client = FakeJellyfinPlaybackClient()
        let expected = TranscodeDelivery(
            isVideoDirect: true,
            isAudioDirect: false,
            videoCodec: "h264",
            audioCodec: "aac",
            transcodeReasons: ["AudioCodecNotSupported"]
        )
        client.transcodingDeliveryResult = .success(expected)
        let service = PlaybackInfoService(client: client)

        let delivery = await service.transcodingDelivery(playSessionID: "ps-1")

        #expect(delivery == expected)
        #expect(client.transcodingDeliveryCalls == ["ps-1"])
    }

    @Test("A failed probe reads as nil")
    func failureYieldsNil() async {
        let client = FakeJellyfinPlaybackClient()
        client.transcodingDeliveryResult = .failure(URLError(.notConnectedToInternet))
        let service = PlaybackInfoService(client: client)

        #expect(await service.transcodingDelivery(playSessionID: "ps-1") == nil)
        #expect(client.transcodingDeliveryCalls == ["ps-1"])
    }
}
