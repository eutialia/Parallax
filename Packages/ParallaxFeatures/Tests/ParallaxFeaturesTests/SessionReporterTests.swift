import CoreMedia
import Foundation
import ParallaxCoreTestSupport
import Testing
import ParallaxTestScaling
@testable import ParallaxFeatures
@testable import ParallaxJellyfin

@MainActor
@Suite("Session reporter", .scaledTimeLimit())
struct SessionReporterTests {
    /// Records whether each final request arrived from a cancelled task: a real one would be
    /// cancelled on the wire and never reach the server.
    actor CancellationSensingReporting: PlaybackReporting {
        private(set) var arrivedCancelled: [String: Bool] = [:]

        func reportStart(_ beat: ProgressBeat) async {}
        func reportProgress(_ beat: ProgressBeat) async {}
        func pingSession(playSessionID: String) async {}

        func reportStopped(_ beat: ProgressBeat) async {
            arrivedCancelled["stopped"] = Task.isCancelled
        }

        func stopEncoding(playSessionID: String) async {
            arrivedCancelled["stopEncoding"] = Task.isCancelled
        }
    }

    @Test("a session's stop report and encode kill go out even when the task closing it is cancelled")
    func finalRequestsOutliveTheTeardown() async {
        let reporting = CancellationSensingReporting()
        let reporter = SessionReporter(playbackInfo: reporting, clock: TestClock())
        reporter.begin(session: PlayerFixtures.resolvedMultiTrackTranscode(playSessionID: "ps-1"))
        _ = await reporter.reportLiveBeat(position: .zero, isPaused: false, opensSession: true)

        let teardown = Task { @MainActor in
            await reporter.reportStoppedIfNeeded(at: CMTime(seconds: 60, preferredTimescale: 600))
            await reporter.stopEncodingIfNeeded()
        }
        teardown.cancel()
        await teardown.value

        #expect(await reporting.arrivedCancelled == ["stopped": false, "stopEncoding": false])
    }
}
