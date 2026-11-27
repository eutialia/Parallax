import Foundation
import Testing
import ParallaxCore
import ParallaxPlayback

/// How a bridged file is laid out for AVPlayer: its segments, its tracks and what each is
/// delivered as, read from the playlists and init segments its delivery serves.
@Suite("MediaDelivery — how a bridged file is laid out", .timeLimit(.minutes(1)))
struct MediaDeliveryLayoutTests {

    /// Each segment's length in milliseconds, from the delivery's playlist for `rendition`.
    private static func milliseconds(_ file: DeliveredFile, _ rendition: String) async throws -> [Double] {
        try await file.segmentSeconds(of: "\(rendition).m3u8").map { ($0 * 1000).rounded() }
    }

    private static func delivered<Value>(
        _ name: String, support: AVPlayerSupport = BridgeFixture.everyDecoder,
        _ read: (DeliveredFile) async throws -> Value
    ) async throws -> Value {
        let file = try await DeliveredFile.start(name, support: support)
        do {
            let value = try await read(file)
            await file.stop()
            return value
        } catch {
            await file.stop()
            throw error
        }
    }

    @Test("index entries half a second apart are merged into two-second segments that add up to the file's length")
    func segmentsCoverTheFileInTwoSecondSteps() async throws {
        let video = try await Self.delivered("h264-mkvmerge") { try await Self.milliseconds($0, "v") }

        #expect(video == [2000, 2000, 2000, 2000, 2000, 2031])
    }

    @Test("a transport stream whose times start at 1.46 s is cut into two-second segments that end where its samples do")
    func transportStreamIsCutWhereItsKeyframesAre() async throws {
        // 288 frames from 1.483 s, a keyframe every half second.
        let video = try await Self.delivered("ts-h264.ts") { try await Self.milliseconds($0, "v") }

        #expect(video == [2000, 2000, 2000, 2000, 2000, 2000])
    }

    @Test("the audio's segments stop at the last one that holds audio, which lasts until the file ends")
    func audioSegmentsStopWhereTheAudioDoes() async throws {
        // Twelve seconds of video in six segments, and eight seconds of audio.
        let (video, audio) = try await Self.delivered("audio-ends-two-segments-early") {
            (try await Self.milliseconds($0, "v"), try await Self.milliseconds($0, "a0"))
        }

        #expect(video == [2000, 2000, 2000, 2000, 2000, 2000])
        #expect(audio == [2000, 2000, 2000, 6000])
    }

    @Test("a file that starts at ten minutes and stores its length, not its end time, still ends where its samples do")
    func lateStartingFileKeepsItsLength() async throws {
        let video = try await Self.delivered("late-start") { try await Self.milliseconds($0, "v") }

        #expect(video == [2000, 2031])
    }

    /// The file's first keyframe interval is 32 s, longer than any segment is cut to.
    @Test("a long keyframe interval is one segment, and the file is delivered")
    func longKeyframeIntervalIsOneSegment() async throws {
        let video = try await Self.delivered("long-span") { try await Self.milliseconds($0, "v") }

        #expect(video.first.map { $0 >= 32_000 } == true, "\(video)")
    }

    @Test("a device that decodes H.264 High 10 or AV1 gets such a file copied, not converted; one that does not gets it converted",
          arguments: [
            ("av1", "av01.0.00M.08", AVPlayerSupport(
                containers: [.mp4, .mov, .hls], videoCodecs: [.h264, .hevc, .vp9],
                audioCodecs: Set(AudioCodec.allCases), decodesH264High10: true)),
            ("h264-high10", "avc1.6e0009", AVPlayerSupport(
                containers: [.mp4, .mov, .hls], videoCodecs: Set(VideoCodec.allCases),
                audioCodecs: Set(AudioCodec.allCases), decodesH264High10: false)),
          ])
    func copiedWhenTheDeviceDecodesIt(name: String, codec: String, withoutDecoder: AVPlayerSupport) async throws {
        let copied = try await Self.delivered(name) { try await $0.master }
        let converted = try await Self.delivered(name, support: withoutDecoder) { try await $0.master }

        #expect(copied.contains(#"CODECS="\#(codec),"#), "\(copied)")
        #expect(converted.contains(#"CODECS="hvc1."#), "\(converted)")
    }

    /// The MP4 forms of the same encodes, which AVPlayer opens: a device with the decoder is
    /// handed the file itself.
    @Test("an MP4 of AV1 or H.264 High 10 is served as it is to a device that decodes it, and bridged as HEVC to one that does not",
          arguments: [
            ("numbered-av1.mp4", AVPlayerSupport(
                containers: [.mp4, .mov, .hls], videoCodecs: [.h264, .hevc, .vp9],
                audioCodecs: Set(AudioCodec.allCases), decodesH264High10: true)),
            ("numbered-h264-high10.mp4", AVPlayerSupport(
                containers: [.mp4, .mov, .hls], videoCodecs: Set(VideoCodec.allCases),
                audioCodecs: Set(AudioCodec.allCases), decodesH264High10: false)),
          ])
    func mp4ServedAsItIsWhenTheDeviceDecodesIt(name: String, withoutDecoder: AVPlayerSupport) async throws {
        let bytes = try BridgeFixture.data(name)
        let served = try await Self.delivered(name) { try await $0.bytes($0.delivery.url.lastPathComponent) }
        let converted = try await Self.delivered(name, support: withoutDecoder) { try await $0.master }

        #expect(served == bytes)
        #expect(converted.contains(#"CODECS="hvc1."#), "\(converted)")
    }

    /// What each audio track is delivered as, from its init segment, and the track playback
    /// starts on.
    private static func audioTracks(of name: String) async throws -> (formats: [String], defaultTrack: Int?) {
        try await delivered(name) { file in
            let master = try await file.master
            let media = master.split(separator: "\n").filter { $0.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO") }
            var formats: [String] = []
            for place in media.indices { formats.append(try sampleEntry(in: try await file.bytes("a\(place)-init.mp4"))) }
            return (formats, media.firstIndex { $0.contains("DEFAULT=YES") })
        }
    }

    /// The four-character code of the first sample entry in an init segment's `stsd` box.
    private static func sampleEntry(in initSegment: Data) throws -> String {
        let stsd = try #require(initSegment.range(of: Data("stsd".utf8)))
        // Version and flags, the entry count, then the entry's size.
        let format = stsd.upperBound + 12
        return String(decoding: initSegment[format..<format + 4], as: UTF8.self)
    }

    @Test("the delivery holds every audio track of a file in the file's order, and starts on the file's default")
    func audioTracksOfAFile() async throws {
        // AAC, AC-3 marked as the default, DTS, FLAC. The DTS is converted to FLAC.
        let tracks = try await Self.audioTracks(of: "four-audio-tracks")

        #expect(tracks.formats == ["mp4a", "ac-3", "fLaC", "fLaC"])
        #expect(tracks.defaultTrack == 1)
    }

    @Test("playback starts on a converted track when it is the file's default")
    func convertedTrackCanBeTheDefault() async throws {
        // AC-3, and DTS marked as the default.
        let tracks = try await Self.audioTracks(of: "ac3-dts-51")

        #expect(tracks.formats == ["ac-3", "fLaC"])
        #expect(tracks.defaultTrack == 1)
    }

    @Test("a track this build has no decoder for is left out, and the file is delivered with the rest")
    func undecodableTrackIsLeftOut() async throws {
        // AAC and TTA.
        let tracks = try await Self.audioTracks(of: "aac-and-tta")

        #expect(tracks.formats == ["mp4a"])
    }

    @Test("a transport stream's delivery holds the audio of the video's own program, and no other program's")
    func audioOfAnotherProgramIsLeftOut() async throws {
        // Program one is H.264 with AAC. Program two is H.264 with AC-3.
        let tracks = try await Self.audioTracks(of: "ts-two-programs.ts")

        #expect(tracks.formats == ["mp4a"])
    }

    @Test("a copied audio track is timed in frames of the length its codec gives them", arguments: [
        ("eac3", Int64(1536)), ("opus", 960), ("flac", 1024),
    ])
    func audioFrameLength(name: String, samples: Int64) async throws {
        let bytes = try await Self.delivered(name) { try await $0.rendition("a0", fetchedIn: Array.init) }
        let times = try readBackSamples(of: bytes, pathExtension: "mp4").map(\.presentation)

        #expect(times.count > 50)
        #expect(zip(times.dropFirst(), times).allSatisfy { $0 - $1 == samples }, "\(times.prefix(8))")
    }
}
