import AVFoundation
import CoreMedia
import Foundation
import Testing
import ParallaxCore
import ParallaxCoreTestSupport
import ParallaxPlayback
import ParallaxPlaybackTestSupport
import ParallaxTestScaling

/// Where AVPlayer waits with no deadline of its own: on the stream's first playlist, or on the
/// segment after the one playing.
enum Stall: String, CaseIterable, CustomTestStringConvertible {
    case beforeReady
    case midPlayback

    var testDescription: String { rawValue }

    /// The long-GOP stream's segments are 13 s long, and AVPlayer turns ready on two of them.
    var withheld: String {
        switch self {
        case .beforeReady: "/main.m3u8"
        case .midPlayback: "/seg2.mp4"
        }
    }
}

@Suite("AVKitEngine — playing what the app plays", .serialized, .scaledTimeLimit())
@MainActor
struct AVKitEngineEndTests {
    @Test("a file that never becomes ready fails at 30 s, and playback that stalls for 45 s fails as a stall",
          arguments: Stall.allCases)
    func watchdogsFireOnARealStall(stall: Stall) async throws {
        let gate = ResponseGate()
        let server = try HLSLoopbackServer.serving(
            directory: AVKitFixtures.longGOPStream, withholding: [stall.withheld], until: gate)
        defer {
            gate.open()
            server.stop()
        }
        let clock = TestClock()
        let engine = AVKitEngine(clock: clock)
        let log = PositionBeatLog(engine)
        try await engine.load(.fixture(url: try await server.baseURL().appending(path: "main.m3u8")))

        let deadline: Duration
        let expected: PlaybackError
        switch stall {
        case .beforeReady:
            (deadline, expected) = (.seconds(30), .loadTimedOut)
            await engine.play()
            try await clock.waitForSleep(dueIn: deadline)
        case .midPlayback:
            (deadline, expected) = (.seconds(45), .networkStalled)
            try await requireEventually({ !log.readyInventories.isEmpty }, "the stream never got ready")
            await engine.seek(to: .seconds(25))
            await engine.play()
            try await requireEventually({ log.beats.contains { $0.isBuffering && $0.seconds >= 25 } },
                                        "playback never stalled on the withheld segment")
            // The load deadline `play()` armed ends with the first beat; until then it would fire first.
            try await pollUntil { clock.pendingSleeps == [deadline] }
            #expect(clock.pendingSleeps == [deadline])
        }

        clock.advance(by: deadline - .seconds(1))
        #expect(clock.pendingSleeps == [.seconds(1)], "the deadline moved or fired early: \(clock.pendingSleeps)")
        #expect(log.failure == nil)
        clock.advance(by: .seconds(1))
        try await pollUntil { log.failure != nil }
        #expect(log.failure == expected)
        log.stop()
        await engine.teardown()
    }

    /// The app calls `play()` again before a stream is ready whenever a reload or the user
    /// resumes it, and each call starts the load deadline over.
    @Test("a stream that plays after two play() calls has no deadline left to fail it")
    func secondPlayLeavesOneLoadDeadline() async throws {
        let server = try HLSLoopbackServer.serving(
            directory: AVKitFixtures.longGOPStream, withholding: [], until: ResponseGate())
        defer { server.stop() }
        let clock = TestClock()
        let engine = AVKitEngine(clock: clock)
        let log = PositionBeatLog(engine)
        try await engine.load(.fixture(url: try await server.baseURL().appending(path: "main.m3u8")))
        await engine.play()
        await engine.play()
        try await requireEventually({ log.beats.contains { !$0.isBuffering && $0.provenance == .observed && $0.seconds > 0.5 } },
                                    "the stream never played", timeout: CITimeScale.seconds(15))

        try await pollUntil { clock.pendingSleeps.isEmpty }
        #expect(clock.pendingSleeps.isEmpty, "a deadline outlived the load: \(clock.pendingSleeps)")
        clock.advance(by: .seconds(30))
        let mark = log.beats.count
        try await requireEventually({ log.beats.dropFirst(mark).contains { $0.provenance == .observed } },
                                    "the stream stopped playing", timeout: CITimeScale.seconds(15))
        #expect(log.failure == nil)
        log.stop()
        await engine.teardown()
    }

    /// The app keeps the engine through `.failed`, so the item stays mounted under the error
    /// scrim and AVPlayer recovers on its own once the link is back. Playing on would be audio
    /// nobody can pause, and a beat from the recovery would put playback back over the error.
    @Test("a stream whose link comes back after its deadline stays failed: the player stops and publishes nothing more",
          arguments: Stall.allCases)
    func recoveryAfterTheDeadlineStaysFailed(stall: Stall) async throws {
        let gate = ResponseGate()
        let server = try HLSLoopbackServer.serving(
            directory: AVKitFixtures.longGOPStream, withholding: [stall.withheld], until: gate)
        defer {
            gate.open()
            server.stop()
        }
        let clock = TestClock()
        let engine = AVKitEngine(clock: clock)
        let log = PositionBeatLog(engine)
        try await engine.load(.fixture(url: try await server.baseURL().appending(path: "main.m3u8")))
        let deadline: Duration
        switch stall {
        case .beforeReady:
            deadline = .seconds(30)
            await engine.play()
        case .midPlayback:
            deadline = .seconds(45)
            try await requireEventually({ !log.readyInventories.isEmpty }, "the stream never got ready")
            await engine.seek(to: .seconds(25))
            await engine.play()
            try await requireEventually({ log.beats.contains { $0.isBuffering && $0.seconds >= 25 } },
                                        "playback never stalled on the withheld segment")
        }
        try await pollUntil { clock.pendingSleeps == [deadline] }
        clock.advance(by: deadline)
        try await requireEventually({ log.failure != nil }, "the deadline never failed the stream")
        let published = (beats: log.beats.count, inventories: log.readyInventories.count)

        gate.open()
        let item = try #require(engine.avPlayer.currentItem)
        switch stall {
        case .beforeReady:
            try await requireEventually({ item.status == .readyToPlay }, "the stream never recovered",
                                        timeout: CITimeScale.seconds(15))
            // Joins the loads the engine's inventory waits on, so a `.ready` it let through is in.
            let asset = try #require(item.asset as? AVURLAsset)
            _ = try? await asset.loadMediaSelectionGroup(for: .audible)
            _ = try? await asset.loadMediaSelectionGroup(for: .legible)
        case .midPlayback:
            try await requireEventually({ item.loadedTimeRanges.contains { $0.timeRangeValue.end.seconds >= 39 } },
                                        "the withheld segment never arrived", timeout: CITimeScale.seconds(15))
        }

        #expect(engine.avPlayer.rate == 0, "the player plays on under the error")
        #expect(log.beats.count == published.beats, "\(log.beats.dropFirst(published.beats))")
        #expect(log.readyInventories.count == published.inventories)
        log.stop()
        await engine.teardown()
    }

    @Test("a load after a failure publishes again")
    func loadAfterAFailurePublishes() async throws {
        let engine = AVKitEngine(clock: TestClock())
        let log = PositionBeatLog(engine)
        // A closed loopback port refuses the connection at once.
        try await engine.load(.fixture(url: try #require(URL(string: "http://127.0.0.1:1/not-a-stream.m3u8"))))
        try await requireEventually({ log.failure != nil }, "the refused stream never failed", timeout: CITimeScale.seconds(15))

        try await engine.load(.fixture(url: AVKitFixtures.tiny))
        try await requireEventually({ !log.readyInventories.isEmpty }, "the load after the failure never got ready",
                                    timeout: CITimeScale.seconds(15))
        log.stop()
        await engine.teardown()
    }

    /// The streams a Jellyfin server lists for the subtitled stream, numbered as Jellyfin numbers
    /// them: the video first.
    private static let subtitledStreams = [
        MediaStreamInfo(index: 0, kind: .video, displayTitle: "H264", language: nil, codec: "h264", channels: nil,
                        isExternal: false, isForced: false, isDefault: true),
        MediaStreamInfo(index: 1, kind: .subtitle, displayTitle: "English - WEBVTT", language: "eng", codec: "webvtt",
                        channels: nil, isExternal: false, isForced: false, isDefault: false),
        MediaStreamInfo(index: 2, kind: .subtitle, displayTitle: "French - Forced - WEBVTT", language: "fre", codec: "webvtt",
                        channels: nil, isExternal: false, isForced: true, isDefault: false),
        MediaStreamInfo(index: 3, kind: .subtitle, displayTitle: "German - WEBVTT", language: "ger", codec: "webvtt",
                        channels: nil, isExternal: false, isForced: false, isDefault: false),
    ]

    @Test("choosing a Jellyfin subtitle shows that subtitle, a forced-only track is offered only as forced, and the option index never shifts by one")
    func jellyfinSubtitleChoice() async throws {
        let server = try HLSLoopbackServer.serving(
            directory: AVKitFixtures.subtitledStream, withholding: [], until: ResponseGate())
        defer { server.stop() }
        let engine = AVKitEngine(clock: TestClock())
        let log = PositionBeatLog(engine)
        try await engine.load(PlayableAsset(
            url: try await server.baseURL().appending(path: "master.m3u8"), startTime: nil,
            mediaStreams: Self.subtitledStreams))
        let cues = ShownCues(on: try #require(engine.avPlayer.currentItem))
        await engine.play()
        try await requireEventually({ !log.readyInventories.isEmpty }, "the stream never got ready")
        let offered = log.readyInventories[0].subtitles

        // AVFoundation also offers a machine translation into each of the host's preferred
        // languages, after the stream's own renditions.
        let french = offered.filter { $0.languageCode == "fr" }
        let frenchAsFull = french.filter { !$0.isForced }
        #expect(frenchAsFull.isEmpty, "the forced-only track was offered as a full one: \(offered)")
        // Each cue names the rendition it was written for.
        let written = ["en": "eng", "fr": "fra", "de": "deu"]
        let own = offered.filter { written[$0.languageCode ?? ""] != nil }
        let fullOwn = own.filter { !$0.isForced }.compactMap(\.languageCode)
        #expect(fullOwn == ["en", "de"], "\(offered)")
        for track in own.reversed() {
            await engine.setSubtitleTrack(track)
            let expected = try #require(written[track.languageCode ?? ""])
            try await pollUntil({ cues.latest == expected }, timeout: CITimeScale.seconds(4))
            #expect(cues.latest == expected, "chose \(track.displayName)")
        }
        log.stop()
        await engine.teardown()
    }

    @Test("a bridged file plays through the app's engine")
    func bridgedFilePlays() async throws {
        let file = try await DeliveredFile.start("frame-numbers")
        let engine = AVKitEngine(clock: TestClock())
        let log = PositionBeatLog(engine)
        try await engine.load(.fixture(url: file.delivery.url))
        let screen = AVPlayerItemVideoOutput.numberedPictures()
        try #require(engine.avPlayer.currentItem).add(screen)
        engine.avPlayer.isMuted = true
        await engine.play()

        try await requireEventually({ log.beats.contains { !$0.isBuffering && $0.provenance == .observed && $0.seconds >= 1 } },
                                    "the engine never played a second of it", timeout: CITimeScale.seconds(15))
        let shown = await screen.framesShown(for: .seconds(1))
        #expect(shown.count > 12, "\(shown.count) pictures shown in a second")
        let misplaced = shown.filter { !$0.isTheSourceFrameForItsTime }
        #expect(misplaced.isEmpty, "\(misplaced)")
        #expect(log.failure == nil)
        log.stop()
        await engine.teardown()
        await file.stop()
    }
}

/// The text of every cue an item shows, as it shows it.
@MainActor
final class ShownCues: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    private let output = AVPlayerItemLegibleOutput()
    private(set) var texts: [String] = []
    var latest: String? { texts.last }

    init(on item: AVPlayerItem) {
        super.init()
        output.setDelegate(self, queue: .main)
        item.add(output)
    }

    nonisolated func legibleOutput(
        _ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
        nativeSampleBuffers: [Any], forItemTime itemTime: CMTime
    ) {
        let shown = strings.map(\.string)
        MainActor.assumeIsolated { texts.append(contentsOf: shown) }
    }
}
