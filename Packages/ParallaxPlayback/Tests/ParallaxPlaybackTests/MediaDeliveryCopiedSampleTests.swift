import Foundation
import Testing
import ParallaxTestScaling
import ParallaxPlayback

/// The samples a bridged delivery copies out of a file, fetched over HTTP and read back by
/// libavformat's MP4 demuxer, which shares no code with the muxer that wrote them. The oracle is
/// the source fixture itself: ffprobe's packet list of it, or libavformat's own read of it.
@Suite("MediaDelivery — copied samples", .scaledTimeLimit())
struct MediaDeliveryCopiedSampleTests {

    @Test(
        "the init segment and every segment, asked for last first, read back as the source's samples, evenly spaced, each decoded no later than it is shown",
        arguments: [
            // Video starts at 104.33 ms (12,520 of 120,000), AAC at 83.33 ms (4,000 of 48,000) and
            // AC-3 at 99.33 ms (4,768 of 48,000): the sources' own offsets, 21 ms and 5 ms before
            // the video.
            ("h264-mkvmerge", "v", 0, Int64(12_520), Int64(5000), Int64(120_000)),
            ("h264-mkvmerge", "a0", 1, 4000, 1024, 48_000), ("h264-mkvmerge", "a1", 2, 4768, 1536, 48_000),
            ("h264-ffmpeg", "v", 0, 12_520, 5000, 120_000),
            ("h264-ffmpeg", "a0", 1, 4000, 1024, 48_000), ("h264-ffmpeg", "a1", 2, 4768, 1536, 48_000),
        ])
    func segmentsReadBackAsTheSourceSamples(
        name: String, rendition: String, stream: Int, first: Int64, step: Int64, timescale: Int64
    ) async throws {
        let file = try await DeliveredFile.start(name)
        let bytes: Data
        do {
            bytes = try await file.rendition(rendition) { $0.reversed() }
            await file.stop()
        } catch {
            await file.stop()
            throw error
        }
        let readBack = try readBackSamples(of: bytes, pathExtension: "mp4")
        let source = try BridgeFixture.sourcePackets(name, stream: stream)

        #expect(readBack.map { BridgeFixture.SourcePacket(md5: $0.md5, isKeyframe: $0.isKeyframe) } == source)
        #expect(readBack.allSatisfy { $0.timescale == timescale })
        // Both fixtures hold evenly spaced samples from first to last, so sample n of a stream
        // displays at exactly `first + n * step`, whatever rounding the container stored.
        #expect(readBack.map(\.presentation).sorted() == source.indices.map { first + Int64($0) * step })
        #expect(zip(readBack, readBack.dropFirst()).allSatisfy { $0.decode < $1.decode })
        #expect(readBack.allSatisfy { $0.decode <= $0.presentation })
    }

    /// A segment is written in fragments of a second or so, and each fragment after the first is
    /// dated on its own. Every fixture's stream 0 is its video and the rest its audio, in order.
    /// Matroska times a picture to the millisecond, and the delivery to its exact place. It
    /// stores laced audio frames under one time, so the audio's own times are its spacing.
    @Test(
        "every segment of a copied rendition, its fragments joined, reads back as the source's samples, the pictures at their source times and the audio evenly spaced",
        arguments: [
            "anamorphic", "audio-ends-early", "audio-ends-two-segments-early", "av1", "dolby-vision-8-1",
            "dolby-vision-8-2", "dolby-vision-8-4", "eac3", "flac", "frame-numbers", "frame-numbers-hevc",
            "h264-ffmpeg", "h264-high10", "h264-mkvmerge", "hdr-hlg", "hdr-pq", "he-aac", "he-aac-v2", "late-start",
            "long-span", "opus",
        ].map { ($0, nil as String?, 0) } + [
            // The third track is DTS, which is converted.
            ("four-audio-tracks", "a2", 0),
            // An MP4 sample of E-AC-3 holds six blocks, and the last of these frames of three
            // has no partner.
            ("eac3-three-blocks", nil, 1),
        ])
    func copiedRenditionsReadBackAsTheSource(name: String, converted: String?, unpaired: Int) async throws {
        let source = try readBackSamples(of: BridgeFixture.data(name), pathExtension: "mkv")
        let file = try await DeliveredFile.start(name)
        var renditions: [(name: String, samples: [ReadbackSample])] = []
        do {
            let audioCount = try await file.master.components(separatedBy: "TYPE=AUDIO").count - 1
            for rendition in ["v"] + (0..<audioCount).map({ "a\($0)" }) where rendition != converted {
                renditions.append((rendition, try readBackSamples(of: try await file.rendition(rendition), pathExtension: "mp4")))
            }
            await file.stop()
        } catch {
            await file.stop()
            throw error
        }

        #expect(renditions.count == Set(source.map(\.stream)).count - (converted == nil ? 0 : 1))
        for (rendition, readBack) in renditions {
            let stream = try #require(rendition == "v" ? 0 : Int(rendition.dropFirst()).map { $0 + 1 })
            let expected = Array(source.filter { $0.stream == stream }.dropLast(rendition == "v" ? 0 : unpaired))
            #expect(readBack.map(\.md5) == expected.map(\.md5), "\(rendition): \(readBack.count) of \(expected.count)")
            #expect(readBack.map(\.isKeyframe) == expected.map(\.isKeyframe), "\(rendition)")
            guard let firstOut = readBack.first, let firstIn = expected.first, readBack.count == expected.count else { continue }
            if rendition != "v" {
                let spacing = Set(zip(readBack.dropFirst(), readBack).map { $0.presentation - $1.presentation })
                #expect(spacing.count <= 1, "\(rendition): \(spacing)")
                continue
            }
            let late = zip(readBack, expected).filter { out, source in
                abs(Double(out.presentation - firstOut.presentation) / Double(out.timescale)
                    - Double(source.presentation - firstIn.presentation) / Double(source.timescale)) > 0.001 + 1e-9
            }
            #expect(late.isEmpty, "\(rendition): \(late.prefix(3))")
        }
    }
}
