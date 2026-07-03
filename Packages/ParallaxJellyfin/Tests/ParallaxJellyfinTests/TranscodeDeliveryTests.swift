import Foundation
import Testing
import JellyfinAPI
@testable import ParallaxJellyfin

/// Mapping tests for the `GET /Sessions` copy-vs-reencode probe. The mapping
/// is a pure static seam (`DefaultJellyfinPlaybackClient.delivery(fromSessions:deviceID:)`)
/// so these run against canned `SessionInfoDto` lists — no live server.
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

    @Test("A video-copy session maps to isVideoDirect == true with codecs, bitrate and reasons")
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
            bitrate: 8_000_000,
            transcodeReasons: ["AudioCodecNotSupported", "ContainerNotSupported"]
        ))
    }

    @Test("A full re-encode session maps both direct flags false")
    func reencodeSessionMaps() {
        let sessions = [
            session(
                deviceID: "dev-1",
                transcodingInfo: transcodingInfo(isVideoDirect: false, isAudioDirect: false)
            )
        ]
        let delivery = DefaultJellyfinPlaybackClient.delivery(fromSessions: sessions, deviceID: "dev-1")
        #expect(delivery?.isVideoDirect == false)
        #expect(delivery?.isAudioDirect == false)
        #expect(delivery?.transcodeReasons == [])
    }

    @Test("Nil direct flags map to false — never claim a copy the server didn't assert")
    func nilDirectFlagsMapFalse() {
        let sessions = [
            session(
                deviceID: "dev-1",
                transcodingInfo: transcodingInfo(isVideoDirect: nil, isAudioDirect: nil)
            )
        ]
        let delivery = DefaultJellyfinPlaybackClient.delivery(fromSessions: sessions, deviceID: "dev-1")
        #expect(delivery?.isVideoDirect == false)
        #expect(delivery?.isAudioDirect == false)
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

    @Test("An empty session list yields nil")
    func emptyListIsNil() {
        #expect(DefaultJellyfinPlaybackClient.delivery(fromSessions: [], deviceID: "dev-1") == nil)
    }
}

@Suite("PlaybackInfoService — transcodingDelivery pass-through")
struct PlaybackInfoServiceTranscodingDeliveryTests {
    @Test("Forwards the playSessionID and returns the client's delivery")
    func passThrough() async throws {
        let client = FakeJellyfinPlaybackClient()
        let expected = TranscodeDelivery(
            isVideoDirect: true,
            isAudioDirect: false,
            videoCodec: "h264",
            audioCodec: "aac",
            bitrate: 4_000_000,
            transcodeReasons: ["AudioCodecNotSupported"]
        )
        client.transcodingDeliveryResult = .success(expected)
        let service = PlaybackInfoService(client: client)

        let delivery = try await service.transcodingDelivery(playSessionID: "ps-1")

        #expect(delivery == expected)
        #expect(client.transcodingDeliveryCalls == ["ps-1"])
    }

    @Test("A nil delivery (no session yet) passes through as nil, not an error")
    func nilPassesThrough() async throws {
        let client = FakeJellyfinPlaybackClient()
        client.transcodingDeliveryResult = .success(nil)
        let service = PlaybackInfoService(client: client)

        let delivery = try await service.transcodingDelivery(playSessionID: "ps-1")

        #expect(delivery == nil)
    }

    @Test("A transport error surfaces as a thrown AppError")
    func transportErrorThrows() async {
        let client = FakeJellyfinPlaybackClient()
        client.transcodingDeliveryResult = .failure(URLError(.notConnectedToInternet))
        let service = PlaybackInfoService(client: client)

        await #expect(throws: (any Error).self) {
            _ = try await service.transcodingDelivery(playSessionID: "ps-1")
        }
    }
}
