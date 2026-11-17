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

    @Test("the plan describes and places each stream from the start of the first segment as it would from the whole of it",
          arguments: [
              "anamorphic", "audio-ends-early", "audio-ends-two-segments-early", "av1", "dolby-vision-8-1",
              "dolby-vision-8-2", "dolby-vision-8-4", "eac3", "flac", "four-audio-tracks", "frame-numbers",
              "frame-numbers-hevc", "h264-ffmpeg", "h264-high10", "h264-mkvmerge", "hdr-hlg", "hdr-pq",
              "he-aac", "he-aac-v2", "late-start", "long-span", "opus", "deep-pyramid-hevc", "sparse-clusters",
          ])
    func openingReadStandsForTheFirstSegment(name: String) async throws {
        let demuxer = try await BridgeFixture.demuxer(name)
        let plan = try await BridgePlan(reading: demuxer, support: BridgeFixture.everyDecoder, showsHDR: true)
        let first = plan.video.segments[0].entries
        let whole = try await demuxer.packets(from: first.lowerBound, to: first.upperBound)

        for track in [plan.video] + plan.audio {
            let packets = whole.filter { $0.stream == track.rendition.stream.index }
            #expect(try SegmentWriter.initSegment(for: track.rendition, describedBy: packets) == track.initSegment)
            if let grid = track.rendition.clock.grid {
                #expect(grid.anchor == packets.compactMap(\.presentationTime).min())
            }
        }
    }

    @Test("a file the bridge cannot deliver is refused with the reason", arguments: [
        ("refused-dolby-vision-5", BridgeRefusal.videoCodec(name: "hevc Main 10, Dolby Vision profile 5")),
        ("refused-tta-audio", .noDeliverableAudio(names: ["tta"])),
        ("refused-one-keyframe", .noCues),
        ("refused-no-duration", .noDuration),
        ("refused-avi-b-frames.avi", .untimedVideo),
        ("refused-asf-wmv.asf", .container(name: "asf")),
        ("refused-asf-h264.asf", .container(name: "asf")),
    ])
    func undeliverableFileIsRefused(name: String, reason: BridgeRefusal) async throws {
        let demuxer = try await BridgeFixture.demuxer(name)
        await #expect(throws: reason) { _ = try await BridgePlan(reading: demuxer, support: BridgeFixture.everyDecoder, showsHDR: true) }
    }

    @Test("AV1 and 10-bit H.264 are delivered as they are to a device that decodes them, and as HEVC to one without that decoder", arguments: [
        ("av1", "av01.0.00M.08", "hvc1.1.6.L30.B0", AVPlayerSupport(
            containers: [.mp4, .mov, .hls], videoCodecs: [.h264, .hevc, .vp9],
            audioCodecs: Set(AudioCodec.allCases), decodesH264High10: true)),
        ("h264-high10", "avc1.6e0009", "hvc1.2.4.L30.B0", AVPlayerSupport(
            containers: [.mp4, .mov, .hls], videoCodecs: Set(VideoCodec.allCases),
            audioCodecs: Set(AudioCodec.allCases), decodesH264High10: false)),
    ])
    func videoNeedsADecoder(name: String, codec: String, converted: String, withoutDecoder: AVPlayerSupport) async throws {
        let demuxer = try await BridgeFixture.demuxer(name)

        #expect(try await BridgePlan(reading: demuxer, support: BridgeFixture.everyDecoder, showsHDR: true).video.rendition.codec == codec)
        #expect(try await BridgePlan(reading: demuxer, support: withoutDecoder, showsHDR: true).video.rendition.codec == converted)
    }

    @Test("the plan holds every audio track of a file in the file's order, and starts on the file's default")
    func audioTracksOfAFile() async throws {
        // AAC, AC-3 marked as the default, DTS, FLAC.
        let plan = try await BridgePlan(reading: BridgeFixture.demuxer("four-audio-tracks"), support: BridgeFixture.everyDecoder, showsHDR: true)

        // The DTS is converted to FLAC.
        #expect(plan.audio.map(\.rendition.codec) == ["mp4a.40.2", "ac-3", "fLaC", "fLaC"])
        #expect(plan.omittedAudio == [])
        #expect(plan.defaultAudio == 1)
        // A copied track is timed in its own frames: 1024 samples for AAC and this FLAC, 1536
        // for AC-3. A converted one is timed sample by sample.
        #expect(plan.audio.map { $0.rendition.clock.grid?.step } == [1024, 1536, nil, 1024])
    }

    @Test("playback starts on a converted track when it is the file's default")
    func convertedTrackCanBeTheDefault() async throws {
        // AC-3, and DTS marked as the default.
        let plan = try await BridgePlan(reading: BridgeFixture.demuxer("ac3-dts-51"), support: BridgeFixture.everyDecoder, showsHDR: true)

        #expect(plan.audio.map(\.rendition.codec) == ["ac-3", "fLaC"])
        #expect(plan.defaultAudio == 1)
    }

    @Test("a track this build has no decoder for is left out by name, and the file plays with the rest")
    func undecodableTrackIsLeftOut() async throws {
        // AAC and TTA.
        let plan = try await BridgePlan(reading: BridgeFixture.demuxer("aac-and-tta"), support: BridgeFixture.everyDecoder, showsHDR: true)

        #expect(plan.audio.map(\.rendition.codec) == ["mp4a.40.2"])
        #expect(plan.omittedAudio == ["tta"])
    }

    @Test("a transport stream's plan holds the audio of the video's own program, and no other program's")
    func audioOfAnotherProgramIsNotThePlans() async throws {
        // Program one is H.264 with AAC. Program two is H.264 with AC-3.
        let plan = try await BridgePlan(reading: BridgeFixture.demuxer("ts-two-programs.ts"), support: BridgeFixture.everyDecoder, showsHDR: true)

        #expect(plan.video.rendition.stream.index == 0)
        #expect(plan.audio.map(\.rendition.codec) == ["mp4a.40.2"])
        #expect(plan.omittedAudio == [])
    }

    @Test("a transport stream whose times start at 1.46 s is cut into two-second segments that end where its samples do")
    func transportStreamIsCutWhereItsKeyframesAre() async throws {
        // 288 frames from 1.483 s, a keyframe every half second.
        let plan = try await BridgePlan(reading: BridgeFixture.demuxer("ts-h264.ts"), support: BridgeFixture.everyDecoder, showsHDR: true)

        #expect(plan.video.segments.map(\.entries) == [0..<4, 4..<8, 8..<12, 12..<16, 16..<20, 20..<24])
        #expect(plan.video.segments.map { ($0.seconds * 1000).rounded() } == [2000, 2000, 2000, 2000, 2000, 2000])
        #expect(plan.audio.map(\.rendition.codec) == ["mp4a.40.2", "ac-3"])
    }

    @Test("an audio track is timed in frames of the length its codec gives them", arguments: [
        ("eac3", Int64(1536)), ("opus", 960), ("flac", 1024),
    ])
    func audioFrameLength(name: String, samples: Int64) async throws {
        let plan = try await BridgePlan(reading: BridgeFixture.demuxer(name), support: BridgeFixture.everyDecoder, showsHDR: true)
        #expect(plan.audio[0].rendition.clock.grid?.step == samples)
    }

    @Test("a file whose index stops is refused where it stops, and a long keyframe interval in the middle plays",
          arguments: [("index-stops", 32 as Int?), ("long-span", nil)])
    func indexThatStopsIsRefused(name: String, stopsAfter: Int?) async throws {
        // Both files have a 32 s keyframe interval from the start. In one the index then stops.
        let demuxer = try await BridgeFixture.demuxer(name)
        let plan = { try await BridgePlan(reading: demuxer, support: BridgeFixture.everyDecoder, showsHDR: true, indexGapLimit: .seconds(20)) }
        if let stopsAfter {
            await #expect(throws: BridgeRefusal.indexGap(after: stopsAfter)) { _ = try await plan() }
            #expect("\(BridgeRefusal.indexGap(after: 3725))" == "no keyframe index after 1:02:05")
        } else {
            #expect(try await plan().video.segments.first?.entries == 0..<1)
        }
    }
}
