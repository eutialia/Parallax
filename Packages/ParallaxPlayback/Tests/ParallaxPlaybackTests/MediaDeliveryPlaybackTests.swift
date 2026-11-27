import AVFoundation
import Foundation
import Testing
import ParallaxTestScaling
import ParallaxPlayback

/// What AVPlayer shows of a file `MediaDelivery` bridges, read from the number each numbered
/// fixture draws into its pictures.
@Suite("MediaDelivery — what AVPlayer shows", .serialized, .scaledTimeLimit())
@MainActor
struct MediaDeliveryPlaybackTests {

    @Test(
        "AVPlayer shows each source frame at its own time, from the start and after a seek past what it had buffered",
        arguments: [
            "frame-numbers", "frame-numbers-hevc",
            // The opening holds pictures shown later than its last: they must not be ranked.
            "deep-pyramid-hevc",
            // Transport streams with no index, cut at keyframes that are not IDR pictures:
            // x265's CRA pictures and x264's recovery points.
            "ts-hevc-open-gop.ts", "ts-h264-open-gop.ts",
        ])
    func avPlayerShowsEachSourceFrameAtItsTime(name: String) async throws {
        try await Self.expectEachSourceFrameAtItsTime(from: PlayedFile(name))
    }

    @Test(
        "AVPlayer shows each source frame of a video converted to HEVC at its own time, from the start and after a seek past what it had buffered",
        // AV1 in 10 bits on a device with no decoder for it, MPEG-2 with open groups of
        // pictures in a transport stream, and MPEG-4 with B-pictures in an AVI, which stores
        // decode times only.
        arguments: ["numbered-av1", "numbered-mpeg2-open-gop.ts", "numbered-mpeg4-b.avi"])
    func avPlayerShowsEachSourceFrameOfConvertedVideo(name: String) async throws {
        let played = try await PlayedFile(name, support: BridgeFixture.fewestDecoders)
        #expect(try await played.file.master.contains(#"CODECS="hvc1"#))
        try await Self.expectEachSourceFrameAtItsTime(from: played)
    }

    @Test(
        "a file with no audio stream plays silent, each source frame at its own time, from the start and after a seek",
        // H.264 that is copied, and MPEG-4 with B-pictures in an AVI that is converted.
        arguments: ["numbered-h264-silent", "numbered-mpeg4-silent.avi"])
    func videoOnlyFilePlaysSilent(name: String) async throws {
        let played = try await PlayedFile(name)
        #expect(!(try await played.file.master.contains("AUDIO")))
        try await Self.expectEachSourceFrameAtItsTime(from: played, hasAudio: false)
    }

    /// One fixture for each container the bridge reads: H.264 copied out of Matroska, a
    /// transport stream and a program stream, Sorenson video in an FLV, MPEG-4 in an AVI and
    /// WMV in an ASF, converted.
    @Test("an MKV, a TS, an FLV, an AVI, a WMV and an MPG each play from their first frame, every frame at its own time, and from a seek",
          arguments: [
            "numbered-h264-silent", "ts-h264-open-gop.ts", "numbered-flv1.flv", "numbered-mpeg4.avi",
            "numbered-wmv2.asf", "numbered-h264.mpg",
          ])
    func everyBridgedContainerPlays(name: String) async throws {
        try await Self.expectFirstFrameAndSeek(from: PlayedFile(name))
    }

    /// AVPlayer opens an HLS presentation where its audio starts, past the pictures before it.
    @Test("an MKV, a TS and an MPG whose copied audio starts 0.3 s after the first picture each play from their first frame, every frame at its own time, and from a seek",
          arguments: [
            "numbered-h264-late-aac", "numbered-h264-late-eac3", "numbered-h264-late-aac.ts", "numbered-h264-late-ac3.mpg",
            "numbered-h264-late-he-aac", "numbered-h264-late-he-aac-v2", "numbered-h264-late-he-aac.ts",
            "numbered-h264-late-flac", "numbered-h264-late-flac-24-bit", "numbered-h264-late-alac", "numbered-h264-late-alac-no-b",
            "numbered-h264-late-opus", "numbered-h264-late-opus-surround",
          ])
    func lateAudioPlaysFromTheFirstFrame(name: String) async throws {
        try await Self.expectFirstFrameAndSeek(from: PlayedFile(name))
    }

    /// Plays a numbered fixture from the start, then from 8.5 s, and stops it.
    private static func expectFirstFrameAndSeek(from played: PlayedFile) async throws {
        let fromStart = await played.framesShown(for: .seconds(3))
        let afterSeek = await played.framesShown(from: 8.5, for: .seconds(2))
        await played.stop()

        #expect(fromStart.count > 48, "\(fromStart)")
        #expect(fromStart.first?.number == 0)
        #expect(fromStart.filter { !$0.isTheSourceFrameForItsTime }.isEmpty, "\(fromStart)")
        #expect(afterSeek.count > 24, "\(afterSeek)")
        // 8.5 s is frame 204.
        #expect(afterSeek.first?.number == 204)
        #expect(afterSeek.filter { !$0.isTheSourceFrameForItsTime }.isEmpty, "\(afterSeek)")
        #expect(played.player.currentItem?.error == nil)
    }

    @Test("AVPlayer plays AC-3 copied out of an MPG from the start and after a seek, fetching its audio on both sides of the seek")
    func avPlayerPlaysAC3CopiedOutOfProgramStream() async throws {
        let played = try await PlayedFile("numbered-h264-ac3.mpg")
        #expect(try await played.file.master.contains(#",ac-3""#))
        let target = try #require(Self.segment(holding: 40.5, startingAt: try await Self.segmentStarts(of: played)))
        try await Self.expectEachSourceFrameAtItsTime(from: played)
        #expect(played.paths.contains("a0-\(target).m4s"), "\(played.paths)")
        #expect(played.player.currentItem?.error == nil)
    }

    /// Plays a minute-long numbered fixture from the start, then from 40.5 s, and stops it.
    private static func expectEachSourceFrameAtItsTime(from played: PlayedFile, hasAudio: Bool = true) async throws {
        let starts = try await segmentStarts(of: played)

        let fromStart = await played.framesShown(for: .seconds(4))
        let requestedBeforeSeek = played.paths
        let afterSeek = await played.framesShown(from: 40.5, for: .seconds(2))
        await played.stop()

        // Past the first segment, whose keyframe is the only one no picture is shown before.
        #expect(fromStart.count > 72, "\(fromStart)")
        #expect(fromStart.first?.number == 0)
        #expect(fromStart.filter { !$0.isTheSourceFrameForItsTime }.isEmpty)
        #expect(afterSeek.count > 24, "\(afterSeek)")
        // 40.5 s is frame 972.
        #expect(afterSeek.first?.number == 972)
        #expect(afterSeek.filter { !$0.isTheSourceFrameForItsTime }.isEmpty)

        // AVPlayer went straight to the segment that holds 40.5 s: nothing that starts between
        // 16 s, past what it had buffered at the start, and that segment was read.
        let target = try #require(segment(holding: 40.5, startingAt: starts))
        let videoSegments = played.paths.compactMap { path -> Int? in
            path.hasPrefix("v-") && path.hasSuffix(".m4s") ? Int(path.dropFirst(2).dropLast(4)) : nil
        }
        #expect(requestedBeforeSeek.contains("v-0.m4s"))
        #expect(requestedBeforeSeek.contains("a0-0.m4s") == hasAudio)
        #expect(videoSegments.contains(target))
        #expect(videoSegments.filter { starts[$0] >= 16 && $0 < target }.isEmpty, "\(videoSegments)")
    }

    /// Seconds from the start at which each video segment plays.
    private static func segmentStarts(of played: PlayedFile) async throws -> [Double] {
        try await played.file.segmentSeconds(of: "v.m3u8").dropLast().reduce(into: [0]) { starts, seconds in
            starts.append(starts[starts.count - 1] + seconds)
        }
    }

    /// The index of the segment that plays at `seconds` from the start.
    private static func segment(holding seconds: Double, startingAt starts: [Double]) -> Int? {
        starts.lastIndex { $0 <= seconds }
    }

    @Test("AVPlayer plays each codec the bridge delivers", arguments: [
        "flac", "eac3", "opus", "av1", "h264-high10", "dolby-vision-8-4",
        // ALAC copied, and FLAC converted from MP3, from TrueHD in 5.1 at 48 and 96 kHz, and from
        // PCM in 7.1.
        "alac", "mp3", "truehd-51", "truehd-96k", "pcm-71",
        // A transport stream copied from a Matroska file: its times are still rounded to the
        // millisecond, under a tick ninety times finer.
        "ts-copied-from-mkv.ts",
        // H.264 as an FLV holds it, and behind start codes with no presentation times in an AVI
        // and an ASF.
        "flv-h264.flv", "avi-h264.avi", "asf-h264.asf",
    ])
    func avPlayerPlaysEachDeliveredCodec(name: String) async throws {
        let played = try await PlayedFile(name)
        let shown = await played.framesShown(for: .seconds(2))
        await played.stop()

        // The fixtures run at 24 frames per second.
        #expect(shown.count > 24)
        #expect(played.player.currentItem?.error == nil)
    }

    @Test("AVPlayer offers every delivered audio track, starts on the file's default, and plays another when asked")
    func avPlayerSwitchesAudioTracks() async throws {
        let played = try await PlayedFile("four-audio-tracks")
        let item = try #require(played.player.currentItem)
        let group = try #require(try await item.asset.loadMediaSelectionGroup(for: .audible))

        // AVPlayer shows a track's language, not the playlist's name for it: the second track's
        // title, "Surround", is not shown. The file spells German "ger".
        #expect(group.options.map(\.displayName) == ["English", "Japanese", "Japanese", "German"])
        #expect(group.options.map(\.extendedLanguageTag) == ["eng", "jpn", "jpn", "ger"])
        _ = await played.framesShown(for: .seconds(1))
        #expect(item.currentMediaSelection.selectedMediaOption(in: group) == group.options[1])
        #expect(played.paths.contains("a1-0.m4s"))
        #expect(!played.paths.contains("a0-0.m4s") && !played.paths.contains("a2-0.m4s"))

        // The third track is DTS, which the bridge converts to FLAC.
        item.select(group.options[2], in: group)
        let shown = await played.framesShown(for: .seconds(2))
        await played.stop()

        #expect(shown.count > 24)
        #expect(played.paths.contains { $0.hasPrefix("a2-") && $0.hasSuffix(".m4s") })
        #expect(item.error == nil)
    }

    @Test("video whose pixels are not square is shown at the shape the file gives it")
    func anamorphicVideoKeepsItsShape() async throws {
        let played = try await PlayedFile("anamorphic")
        let size = try #require(played.player.currentItem?.presentationSize)
        await played.stop()

        // 160 by 90 stored, with pixels a third wider than tall.
        #expect((size.width.rounded(), size.height) == (213, 90))
    }

    @Test("a file whose audio ends before its video plays to its last frame")
    func videoOutlastsAudio() async throws {
        let played = try await PlayedFile("audio-ends-early")
        // The audio ends at 11 s and the video at 12 s. AVPlayer ends an item where its
        // shortest rendition does.
        let shown = await played.framesShown(from: 10, for: .seconds(3))
        await played.stop()

        #expect(shown.first?.number == 240)
        #expect(shown.last?.number == 287)
        #expect(shown.filter { !$0.isTheSourceFrameForItsTime }.isEmpty)
    }

    @Test("a file whose audio ends two segments before its video plays to its last frame, from inside the audio and from past it", arguments: [6.0, 9.0])
    func videoOutlastsAudioBySegments(start: Double) async throws {
        let played = try await PlayedFile("audio-ends-two-segments-early")
        // The audio ends at 8 s and the video at 12 s.
        let shown = await played.framesShown(from: start, for: .seconds(12 - start + 2))
        await played.stop()

        #expect(shown.first?.number == Int(start * 24))
        #expect(shown.last?.number == 287)
        #expect(shown.filter { !$0.isTheSourceFrameForItsTime }.isEmpty)
        #expect(!played.paths.contains("a0-4.m4s"))
    }

    @Test("the same clip is delivered with the same video and audio codecs from every container the bridge reads",
          .disabled("Pending: needs H.264 with B-frames copied from an AVI, a WMV and an MPG"))
    func sameClipIsDeliveredTheSameFromEveryContainer() async throws {}

    @Test("H.264 with B-frames in an AVI or WMV is copied, and AVPlayer shows each source frame at its own time, from the start and after a seek",
          .disabled("Pending: H.264 timed by its picture order count"))
    func h264WithBFramesInDecodeTimeContainersIsCopied() async throws {}

    @Test("H.264 in an MPG or VOB is copied, and AVPlayer shows each source frame at its own time, from the start and after a seek",
          .disabled("Pending: H.264 timed by its picture order count"))
    func h264InProgramStreamIsCopied() async throws {}
}
