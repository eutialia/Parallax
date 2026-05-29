import Foundation
import Testing
import JellyfinAPI
@testable import ParallaxJellyfin

@Suite("PlaybackInfoService — progress reporting")
struct PlaybackInfoServiceReportTests {
    private func beat(position: Int, paused: Bool = false, method: PlaybackMethod = .directStream) -> ProgressBeat {
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
