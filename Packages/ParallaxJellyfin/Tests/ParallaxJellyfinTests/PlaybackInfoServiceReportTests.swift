import Foundation
import Testing
import JellyfinAPI
import ParallaxCoreTestSupport
@testable import ParallaxJellyfin

@Suite("PlaybackInfoService — progress reporting")
struct PlaybackInfoServiceReportTests {
    private func beat(position: Int, paused: Bool = false, method: PlaybackMethod = .directPlay) -> ProgressBeat {
        ProgressBeat(
            positionTicks: position,
            isPaused: paused,
            method: method,
            itemID: "item-1",
            mediaSourceID: "ms-1",
            playSessionID: "ps-1"
        )
    }

    @Test("reportStart POSTs a PlaybackStateInfo with the play method and ids")
    func startReports() async {
        let fake = FakeJellyfinPlaybackClient()
        let service = PlaybackInfoService(client: fake, clock: TestClock())
        await service.reportStart(beat(position: 0, method: .transcode))
        #expect(fake.startInfos.count == 1)
        #expect(fake.startInfos.first?.itemID == "item-1")
        #expect(fake.startInfos.first?.mediaSourceID == "ms-1")
        #expect(fake.startInfos.first?.playSessionID == "ps-1")
        #expect(fake.startInfos.first?.playMethod == .transcode)
        #expect(fake.startInfos.first?.positionTicks == 0)
    }

    /// The window itself is the service's policy, so the beats are placed RELATIVE to it: a
    /// re-tuned interval must not silently break this test, and the boundary is inclusive
    /// (`elapsed >= interval` reports). The first progress beat after a start always goes out.
    @Test("reportProgress drops beats inside the throttle window and sends the first one past it")
    func progressThrottle() async {
        let window = PlaybackInfoService.progressThrottle
        let fake = FakeJellyfinPlaybackClient()
        let clock = TestClock()
        let service = PlaybackInfoService(client: fake, clock: clock)
        await service.reportStart(beat(position: 0))
        await service.reportProgress(beat(position: 5_000_000))     // first after the start — sent
        clock.advance(by: window / 10 * 3)
        await service.reportProgress(beat(position: 10_000_000))    // dropped
        clock.advance(by: window / 10 * 6)
        await service.reportProgress(beat(position: 50_000_000))    // dropped
        clock.advance(by: window / 10)
        await service.reportProgress(beat(position: 110_000_000))   // on the edge — sent
        #expect(fake.progressInfos.map(\.positionTicks) == [5_000_000, 110_000_000])
    }

    /// After a beat is sent the window restarts from it, so a second beat one window later is also
    /// sent — otherwise long playbacks would report once and go quiet.
    @Test("The window restarts from each sent beat")
    func progressThrottleWindowRestarts() async {
        let window = PlaybackInfoService.progressThrottle
        let fake = FakeJellyfinPlaybackClient()
        let clock = TestClock()
        let service = PlaybackInfoService(client: fake, clock: clock)
        await service.reportStart(beat(position: 0))
        await service.reportProgress(beat(position: 100))
        clock.advance(by: window / 2)
        await service.reportProgress(beat(position: 200))   // inside the window
        clock.advance(by: window / 2)
        await service.reportProgress(beat(position: 300))   // past it
        #expect(fake.progressInfos.map(\.positionTicks) == [100, 300])
    }

    @Test("A pause flip sends an immediate progress beat regardless of throttle")
    func pauseFlipImmediate() async {
        let fake = FakeJellyfinPlaybackClient()
        let clock = TestClock()
        let service = PlaybackInfoService(client: fake, clock: clock)
        await service.reportStart(beat(position: 0, paused: false))
        await service.reportProgress(beat(position: 10_000_000))
        clock.advance(by: .seconds(2))
        await service.reportProgress(beat(position: 20_000_000, paused: true))  // pause flip at 2s
        #expect(fake.progressInfos.map(\.isPaused) == [false, true])
    }

    @Test("reportStopped POSTs a PlaybackStopInfo and is best-effort")
    func stoppedReports() async {
        let fake = FakeJellyfinPlaybackClient()
        let service = PlaybackInfoService(client: fake, clock: TestClock())
        await service.reportStopped(beat(position: 99_000_000))
        #expect(fake.stoppedInfos.count == 1)
        #expect(fake.stoppedInfos.first?.positionTicks == 99_000_000)
        #expect(fake.stoppedInfos.first?.playSessionID == "ps-1")
    }

    @Test("Session-lifecycle calls forward the play session and nothing else", arguments: [SessionCall.stopEncoding, .ping])
    func sessionCallsForwardThePlaySession(call: SessionCall) async {
        let fake = FakeJellyfinPlaybackClient()
        let service = PlaybackInfoService(client: fake, clock: TestClock())

        switch call {
        case .stopEncoding:
            await service.stopEncoding(playSessionID: "ps-1")
            #expect(fake.stopEncodingSessionIDs == ["ps-1"])
            #expect(fake.pingSessionIDs.isEmpty)
        case .ping:
            await service.pingSession(playSessionID: "ps-1")
            #expect(fake.pingSessionIDs == ["ps-1"])
            #expect(fake.stopEncodingSessionIDs.isEmpty)
        }
    }

    enum SessionCall: Sendable { case stopEncoding, ping }
}

@Suite("PlaybackInfoService — track selection write-back")
struct PlaybackInfoServiceTrackSelectionTests {
    private func config(
        rememberAudio: Bool? = nil,
        audioLanguage: String? = nil
    ) -> UserConfiguration {
        UserConfiguration(
            audioLanguagePreference: audioLanguage,
            isRememberAudioSelections: rememberAudio
        )
    }

    @Test("Audio pick writes the normalized language into the configuration")
    func audioWriteBack() async {
        let fake = FakeJellyfinPlaybackClient()
        fake.userConfigurationResult = .success(config(audioLanguage: "eng"))
        let service = PlaybackInfoService(client: fake, clock: TestClock())
        await service.rememberTrackSelection(.audio(languageCode: "fr"))
        #expect(fake.updatedUserConfigurations.count == 1)
        #expect(fake.updatedUserConfigurations.first?.audioLanguagePreference == "fra")
    }

    @Test("Audio pick is a no-op when the preference already matches (any dialect)")
    func audioNoOpWhenSame() async {
        let fake = FakeJellyfinPlaybackClient()
        fake.userConfigurationResult = .success(config(audioLanguage: "eng"))
        let service = PlaybackInfoService(client: fake, clock: TestClock())
        await service.rememberTrackSelection(.audio(languageCode: "en"))
        #expect(fake.updatedUserConfigurations.isEmpty)
    }

    @Test("Remember-audio opt-out blocks the write")
    func audioOptOut() async {
        let fake = FakeJellyfinPlaybackClient()
        fake.userConfigurationResult = .success(config(rememberAudio: false))
        let service = PlaybackInfoService(client: fake, clock: TestClock())
        await service.rememberTrackSelection(.audio(languageCode: "fr"))
        #expect(fake.updatedUserConfigurations.isEmpty)
    }

    @Test("A track without a language tag never moves the preference")
    func audioNoLanguageNoWrite() async {
        let fake = FakeJellyfinPlaybackClient()
        fake.userConfigurationResult = .success(config())
        let service = PlaybackInfoService(client: fake, clock: TestClock())
        await service.rememberTrackSelection(.audio(languageCode: nil))
        #expect(fake.userConfigurationFetchCount == 0)
        #expect(fake.updatedUserConfigurations.isEmpty)
    }

    /// An AUDIO pick keeps writing alpha-3: audio tracks are never script-tagged
    /// in the wild, and the server expands alpha-3 to the B/T pair for them.
    @Test("An audio pick stays alpha-3 even for a culture-row tag")
    func audioIgnoresCultureRows() async {
        let fake = FakeJellyfinPlaybackClient()
        fake.userConfigurationResult = .success(config())
        let service = PlaybackInfoService(client: fake, clock: TestClock())
        await service.rememberTrackSelection(.audio(languageCode: "zh-Hans"))
        #expect(fake.updatedUserConfigurations.first?.audioLanguagePreference == "zho")
    }

    @Test("A failed configuration fetch is swallowed and nothing is written back")
    func failuresSwallowed() async {
        let fake = FakeJellyfinPlaybackClient()
        fake.userConfigurationResult = .failure(FakeJellyfinPlaybackClient.FakeError.reportFailed)
        let service = PlaybackInfoService(client: fake, clock: TestClock())
        await service.rememberTrackSelection(.audio(languageCode: "fr"))
        #expect(fake.updatedUserConfigurations.isEmpty)
    }
}
