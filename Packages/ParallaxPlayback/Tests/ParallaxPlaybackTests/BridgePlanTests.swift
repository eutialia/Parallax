import Foundation
import Testing
import ParallaxCore
import ParallaxTestScaling
@testable import ParallaxPlayback

@Suite("BridgePlan", .scaledTimeLimit())
struct BridgePlanTests {

    @Test("index entries half a second apart are merged into two-second segments that add up to the file's length")
    func segmentsCoverTheFileInTwoSecondSteps() async throws {
        let plan = try await BridgePlan(reading: BridgeFixture.demuxer("h264-mkvmerge"), support: BridgeFixture.everyDecoder, showsHDR: true)

        #expect(plan.video.segments.map(\.entries) == [0..<4, 4..<8, 8..<12, 12..<16, 16..<20, 20..<24])
        #expect(plan.video.segments.map { ($0.seconds * 1000).rounded() } == [2000, 2000, 2000, 2000, 2000, 2031])
    }

    @Test("the audio's segments stop at the last one that holds audio, which lasts until the file ends")
    func audioSegmentsStopWhereTheAudioDoes() async throws {
        // Twelve seconds of video in six segments, and eight seconds of audio.
        let plan = try await BridgePlan(reading: BridgeFixture.demuxer("audio-ends-two-segments-early"), support: BridgeFixture.everyDecoder, showsHDR: true)

        #expect(plan.video.segments.map { ($0.seconds * 1000).rounded() } == [2000, 2000, 2000, 2000, 2000, 2000])
        #expect(plan.audio[0].segments.map { ($0.seconds * 1000).rounded() } == [2000, 2000, 2000, 6000])
        #expect(plan.audio[0].segments.last?.end == plan.video.segments.last?.end)
    }

    @Test("a file that starts at ten minutes and stores its length, not its end time, still ends where its samples do")
    func lateStartingFileKeepsItsLength() async throws {
        let plan = try await BridgePlan(reading: BridgeFixture.demuxer("late-start"), support: BridgeFixture.everyDecoder, showsHDR: true)

        #expect(plan.video.segments.map { ($0.seconds * 1000).rounded() } == [2000, 2031])
    }

    @Test("the video and the first deliverable audio stream share one origin that keeps every time at or above zero")
    func renditionsShareAnOriginAboveZero() async throws {
        let plan = try await BridgePlan(reading: BridgeFixture.demuxer("h264-mkvmerge"), support: BridgeFixture.everyDecoder, showsHDR: true)
        let video = plan.video.rendition, audio = plan.audio[0].rendition

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
        ("refused-dolby-vision-5", .videoCodec(name: "hevc Main 10, Dolby Vision profile 5")),
        ("refused-dts-audio", .noDeliverableAudio(names: ["dts DTS"])),
        ("refused-ld-aac", .noDeliverableAudio(names: ["aac LD"])),
        ("refused-one-keyframe", .noCues),
        ("refused-no-duration", .noDuration),
    ])
    func undeliverableFileIsRefused(name: String, reason: BridgeRefusal) async throws {
        let demuxer = try await BridgeFixture.demuxer(name)
        await #expect(throws: reason) { _ = try await BridgePlan(reading: demuxer, support: BridgeFixture.everyDecoder, showsHDR: true) }
    }

    @Test("AV1 and 10-bit H.264 are delivered to a device that decodes them and refused on one without that decoder", arguments: [
        ("av1", "av01.0.00M.08", "av1 Main", AVPlayerSupport(
            containers: [.mp4, .mov, .hls], videoCodecs: [.h264, .hevc, .vp9],
            audioCodecs: Set(AudioCodec.allCases), decodesH264High10: true)),
        ("h264-high10", "avc1.6e0009", "h264 High 10", AVPlayerSupport(
            containers: [.mp4, .mov, .hls], videoCodecs: Set(VideoCodec.allCases),
            audioCodecs: Set(AudioCodec.allCases), decodesH264High10: false)),
    ])
    func videoNeedsADecoder(name: String, codec: String, refused: String, withoutDecoder: AVPlayerSupport) async throws {
        let demuxer = try await BridgeFixture.demuxer(name)

        #expect(try await BridgePlan(reading: demuxer, support: BridgeFixture.everyDecoder, showsHDR: true).video.rendition.codec == codec)
        await #expect(throws: BridgeRefusal.videoCodec(name: refused)) {
            _ = try await BridgePlan(reading: demuxer, support: withoutDecoder, showsHDR: true)
        }
    }

    @Test("the plan holds every audio track it can deliver, names the ones it cannot, and starts on the file's default")
    func audioTracksOfAFile() async throws {
        // AAC, AC-3 marked as the default, DTS, FLAC.
        let plan = try await BridgePlan(reading: BridgeFixture.demuxer("four-audio-tracks"), support: BridgeFixture.everyDecoder, showsHDR: true)

        #expect(plan.audio.map(\.rendition.codec) == ["mp4a.40.2", "ac-3", "fLaC"])
        #expect(plan.omittedAudio == ["dts DTS"])
        #expect(plan.defaultAudio == 1)
        // Each track is timed in its own frames: 1024 samples for AAC and this FLAC, 1536 for AC-3.
        #expect(plan.audio.map { $0.rendition.clock.grid?.step } == [1024, 1536, 1024])
    }

    @Test("an audio track is timed in frames of the length its codec gives them", arguments: [
        ("eac3", Int64(1536)), ("opus", 960), ("flac", 1024),
    ])
    func audioFrameLength(name: String, samples: Int64) async throws {
        let plan = try await BridgePlan(reading: BridgeFixture.demuxer(name), support: BridgeFixture.everyDecoder, showsHDR: true)
        #expect(plan.audio[0].rendition.clock.grid?.step == samples)
    }

    @Test("a segment larger than the limit is refused with its size")
    func oversizedSegmentIsRefused() async throws {
        let demuxer = try await BridgeFixture.demuxer("h264-mkvmerge")
        // Six segments share 930,719 bytes, so the largest holds at least a sixth of them.
        await #expect {
            _ = try await BridgePlan(reading: demuxer, support: BridgeFixture.everyDecoder, showsHDR: true, segmentByteLimit: 100_000)
        } throws: {
            if case BridgeRefusal.segmentTooLarge(let bytes) = $0 { (155_120...930_719).contains(bytes) } else { false }
        }
    }
}
