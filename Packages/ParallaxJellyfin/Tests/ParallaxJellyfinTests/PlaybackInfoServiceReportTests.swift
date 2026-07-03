import Foundation
import Testing
import JellyfinAPI
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
        let service = PlaybackInfoService(client: fake)
        await service.reportStart(beat(position: 0, method: .transcode))
        #expect(fake.startInfos.count == 1)
        #expect(fake.startInfos.first?.itemID == "item-1")
        #expect(fake.startInfos.first?.mediaSourceID == "ms-1")
        #expect(fake.startInfos.first?.playSessionID == "ps-1")
        #expect(fake.startInfos.first?.playMethod == .transcode)
        #expect(fake.startInfos.first?.positionTicks == 0)
    }

    @Test("reportProgress throttles to ~10s between beats")
    func progressThrottle() async {
        let fake = FakeJellyfinPlaybackClient()
        let service = PlaybackInfoService(client: fake)
        await service.reportStart(beat(position: 0))            // primes lastReport at now=0
        await service.reportProgress(beat(position: 10_000_000), now: 3)   // 3s elapsed — dropped
        await service.reportProgress(beat(position: 50_000_000), now: 9)   // 9s — still dropped
        await service.reportProgress(beat(position: 110_000_000), now: 11) // 11s — sent
        #expect(fake.progressInfos.count == 1)
        #expect(fake.progressInfos.first?.positionTicks == 110_000_000)
    }

    @Test("A pause flip sends an immediate progress beat regardless of throttle")
    func pauseFlipImmediate() async {
        let fake = FakeJellyfinPlaybackClient()
        let service = PlaybackInfoService(client: fake)
        await service.reportStart(beat(position: 0, paused: false))
        await service.reportProgress(beat(position: 20_000_000, paused: true), now: 2)  // pause flip at 2s
        #expect(fake.progressInfos.count == 1)
        #expect(fake.progressInfos.first?.isPaused == true)
    }

    @Test("reportStopped POSTs a PlaybackStopInfo and is best-effort")
    func stoppedReports() async {
        let fake = FakeJellyfinPlaybackClient()
        let service = PlaybackInfoService(client: fake)
        await service.reportStopped(beat(position: 99_000_000))
        #expect(fake.stoppedInfos.count == 1)
        #expect(fake.stoppedInfos.first?.positionTicks == 99_000_000)
        #expect(fake.stoppedInfos.first?.playSessionID == "ps-1")
    }

    @Test("stopEncoding DELETEs the session's active encoding and is best-effort")
    func stopEncodingForwards() async {
        let fake = FakeJellyfinPlaybackClient()
        let service = PlaybackInfoService(client: fake)
        await service.stopEncoding(playSessionID: "ps-1")
        #expect(fake.stopEncodingSessionIDs == ["ps-1"])
    }

    @Test("A thrown stopEncoding is non-fatal — it does not propagate")
    func stopEncodingFailureSwallowed() async {
        let fake = FakeJellyfinPlaybackClient()
        fake.stopEncodingError = FakeJellyfinPlaybackClient.FakeError.reportFailed
        let service = PlaybackInfoService(client: fake)
        await service.stopEncoding(playSessionID: "ps-1")
        #expect(fake.stopEncodingSessionIDs == ["ps-1"])
    }

    @Test("pingSession POSTs the session keepalive and is best-effort")
    func pingForwards() async {
        let fake = FakeJellyfinPlaybackClient()
        let service = PlaybackInfoService(client: fake)
        await service.pingSession(playSessionID: "ps-1")
        #expect(fake.pingSessionIDs == ["ps-1"])
    }

    @Test("A thrown ping is non-fatal — it does not propagate")
    func pingFailureSwallowed() async {
        let fake = FakeJellyfinPlaybackClient()
        fake.pingError = FakeJellyfinPlaybackClient.FakeError.reportFailed
        let service = PlaybackInfoService(client: fake)
        await service.pingSession(playSessionID: "ps-1")
        #expect(fake.pingSessionIDs == ["ps-1"])
    }

    @Test("A thrown report is non-fatal — it does not propagate")
    func reportFailureSwallowed() async {
        let fake = FakeJellyfinPlaybackClient()
        fake.startError = FakeJellyfinPlaybackClient.FakeError.reportFailed
        fake.progressError = FakeJellyfinPlaybackClient.FakeError.reportFailed
        fake.stoppedError = FakeJellyfinPlaybackClient.FakeError.reportFailed
        let service = PlaybackInfoService(client: fake)
        // None of these throw — the policy logs and continues.
        await service.reportStart(beat(position: 0))
        await service.reportProgress(beat(position: 110_000_000), now: 11)
        await service.reportStopped(beat(position: 99_000_000))
        #expect(fake.startInfos.count == 1)
        #expect(fake.stoppedInfos.count == 1)
    }
}

@Suite("PlaybackInfoService — track selection write-back")
struct PlaybackInfoServiceTrackSelectionTests {
    private func config(
        rememberAudio: Bool? = nil,
        rememberSubtitles: Bool? = nil,
        audioLanguage: String? = nil,
        subtitleLanguage: String? = nil,
        subtitleMode: SubtitlePlaybackMode? = nil
    ) -> UserConfiguration {
        UserConfiguration(
            audioLanguagePreference: audioLanguage,
            isRememberAudioSelections: rememberAudio,
            isRememberSubtitleSelections: rememberSubtitles,
            subtitleLanguagePreference: subtitleLanguage,
            subtitleMode: subtitleMode
        )
    }

    @Test("Audio pick writes the normalized language into the configuration")
    func audioWriteBack() async {
        let fake = FakeJellyfinPlaybackClient()
        fake.userConfigurationResult = .success(config(audioLanguage: "eng"))
        let service = PlaybackInfoService(client: fake)
        await service.rememberTrackSelection(.audio(languageCode: "fr"))
        #expect(fake.updatedUserConfigurations.count == 1)
        #expect(fake.updatedUserConfigurations.first?.audioLanguagePreference == "fra")
    }

    @Test("Audio pick is a no-op when the preference already matches (any dialect)")
    func audioNoOpWhenSame() async {
        let fake = FakeJellyfinPlaybackClient()
        fake.userConfigurationResult = .success(config(audioLanguage: "eng"))
        let service = PlaybackInfoService(client: fake)
        await service.rememberTrackSelection(.audio(languageCode: "en"))
        #expect(fake.updatedUserConfigurations.isEmpty)
    }

    @Test("Remember-audio opt-out blocks the write")
    func audioOptOut() async {
        let fake = FakeJellyfinPlaybackClient()
        fake.userConfigurationResult = .success(config(rememberAudio: false))
        let service = PlaybackInfoService(client: fake)
        await service.rememberTrackSelection(.audio(languageCode: "fr"))
        #expect(fake.updatedUserConfigurations.isEmpty)
    }

    @Test("A track without a language tag never moves the preference")
    func audioNoLanguageNoWrite() async {
        let fake = FakeJellyfinPlaybackClient()
        fake.userConfigurationResult = .success(config())
        let service = PlaybackInfoService(client: fake)
        await service.rememberTrackSelection(.audio(languageCode: nil))
        #expect(fake.updatedUserConfigurations.isEmpty)
    }

    @Test("Subtitle pick writes language and escalates mode out of None only")
    func subtitleWriteBack() async {
        let fake = FakeJellyfinPlaybackClient()
        fake.userConfigurationResult = .success(config(subtitleMode: SubtitlePlaybackMode.none))
        let service = PlaybackInfoService(client: fake)
        await service.rememberTrackSelection(.subtitles(languageCode: "ger"))
        #expect(fake.updatedUserConfigurations.first?.subtitleLanguagePreference == "deu")
        #expect(fake.updatedUserConfigurations.first?.subtitleMode == .always)
    }

    @Test("Subtitle pick keeps an explicit Smart mode")
    func subtitleKeepsSmartMode() async {
        let fake = FakeJellyfinPlaybackClient()
        fake.userConfigurationResult = .success(config(subtitleLanguage: "eng", subtitleMode: .smart))
        let service = PlaybackInfoService(client: fake)
        await service.rememberTrackSelection(.subtitles(languageCode: "fre"))
        #expect(fake.updatedUserConfigurations.first?.subtitleLanguagePreference == "fra")
        #expect(fake.updatedUserConfigurations.first?.subtitleMode == .smart)
    }

    @Test("Subtitles off persists SubtitleMode = None, once")
    func subtitlesOff() async {
        let fake = FakeJellyfinPlaybackClient()
        fake.userConfigurationResult = .success(config(subtitleMode: .always))
        let service = PlaybackInfoService(client: fake)
        await service.rememberTrackSelection(.subtitles(languageCode: nil))
        #expect(fake.updatedUserConfigurations.first?.subtitleMode == SubtitlePlaybackMode.none)

        // Already None → no redundant POST.
        fake.userConfigurationResult = .success(config(subtitleMode: SubtitlePlaybackMode.none))
        await service.rememberTrackSelection(.subtitles(languageCode: nil))
        #expect(fake.updatedUserConfigurations.count == 1)
    }

    @Test("A failed fetch or update is swallowed (never disturbs playback)")
    func failuresSwallowed() async {
        let fake = FakeJellyfinPlaybackClient()
        fake.userConfigurationResult = .failure(FakeJellyfinPlaybackClient.FakeError.reportFailed)
        let service = PlaybackInfoService(client: fake)
        await service.rememberTrackSelection(.audio(languageCode: "fr"))
        #expect(fake.updatedUserConfigurations.isEmpty)
    }
}
