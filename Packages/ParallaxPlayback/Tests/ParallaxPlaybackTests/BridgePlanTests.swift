import Foundation
import Testing
import ParallaxTestScaling
@testable import ParallaxPlayback

@Suite("BridgePlan", .scaledTimeLimit())
struct BridgePlanTests {

    @Test("index entries half a second apart are merged into two-second segments that add up to the file's length")
    func segmentsCoverTheFileInTwoSecondSteps() async throws {
        let plan = try await BridgePlan(reading: BridgeFixture.demuxer("h264-mkvmerge"))

        #expect(plan.video.segments.map(\.entries) == [0..<4, 4..<8, 8..<12, 12..<16, 16..<20, 20..<24])
        #expect(plan.video.segments.map { ($0.seconds * 1000).rounded() } == [2000, 2000, 2000, 2000, 2000, 2031])
    }

    @Test("the audio's segments stop at the last one that holds audio, which lasts until the file ends")
    func audioSegmentsStopWhereTheAudioDoes() async throws {
        // Twelve seconds of video in six segments, and eight seconds of audio.
        let plan = try await BridgePlan(reading: BridgeFixture.demuxer("audio-ends-two-segments-early"))

        #expect(plan.video.segments.map { ($0.seconds * 1000).rounded() } == [2000, 2000, 2000, 2000, 2000, 2000])
        #expect(plan.audio.segments.map { ($0.seconds * 1000).rounded() } == [2000, 2000, 2000, 6000])
        #expect(plan.audio.segments.last?.end == plan.video.segments.last?.end)
    }

    @Test("a file that starts at ten minutes and stores its length, not its end time, still ends where its samples do")
    func lateStartingFileKeepsItsLength() async throws {
        let plan = try await BridgePlan(reading: BridgeFixture.demuxer("late-start"))

        #expect(plan.video.segments.map { ($0.seconds * 1000).rounded() } == [2000, 2031])
    }

    @Test("the video and the first deliverable audio stream share one origin that keeps every time at or above zero")
    func renditionsShareAnOriginAboveZero() async throws {
        let plan = try await BridgePlan(reading: BridgeFixture.demuxer("h264-mkvmerge"))
        let video = plan.video.rendition, audio = plan.audio.rendition

        #expect(video.stream.index == 0)
        #expect(audio.stream.index == 1)
        // The video decodes two frames (83.33 ms) ahead and the audio starts at -21 ms.
        #expect(video.decodeLead == 10_000)
        #expect(video.clock == MediaClock(
            timescale: 120_000, origin: 104_333_334,
            grid: .init(anchor: 0, step: 5000, tolerance: 1_000_000)))
        #expect(audio.clock == MediaClock(
            timescale: 48_000, origin: 104_333_334,
            grid: .init(anchor: -21_000_000, step: 1024, tolerance: .max)))
    }

    @Test("a file the bridge cannot deliver is refused with the reason", arguments: [
        ("refused-mpeg4-video", BridgeRefusal.videoCodec(name: "mpeg4 Simple Profile")),
        ("refused-high10-video", .videoCodec(name: "h264 High 10")),
        ("refused-dolby-vision-5", .videoCodec(name: "hevc Main 10, Dolby Vision profile 5")),
        ("refused-flac-audio", .noDeliverableAudio(names: ["flac"])),
        ("refused-ld-aac", .noDeliverableAudio(names: ["aac LD"])),
        ("refused-one-keyframe", .noCues),
        ("refused-no-duration", .noDuration),
    ])
    func undeliverableFileIsRefused(name: String, reason: BridgeRefusal) async throws {
        let demuxer = try await BridgeFixture.demuxer(name)
        await #expect(throws: reason) { _ = try await BridgePlan(reading: demuxer) }
    }

    @Test("a segment larger than the limit is refused with its size")
    func oversizedSegmentIsRefused() async throws {
        let demuxer = try await BridgeFixture.demuxer("h264-mkvmerge")
        // Six segments share 930,719 bytes, so the largest holds at least a sixth of them.
        await #expect {
            _ = try await BridgePlan(reading: demuxer, segmentByteLimit: 100_000)
        } throws: {
            if case BridgeRefusal.segmentTooLarge(let bytes) = $0 { (155_120...930_719).contains(bytes) } else { false }
        }
    }
}
