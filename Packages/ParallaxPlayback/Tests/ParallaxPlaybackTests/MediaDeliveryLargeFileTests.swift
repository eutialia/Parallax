import AVFoundation
import Foundation
import Synchronization
import Testing
import ParallaxCore
import ParallaxCoreTestSupport
import ParallaxPlayback

/// A delivery of a file too large to read whole, and of reads that stick or fail once it plays.
@Suite("MediaDelivery — a large file, and reads that stick or fail", .serialized, .timeLimit(.minutes(1)))
struct MediaDeliveryLargeFileTests {

    /// Sampled until no stretch of 8 MB is left unread, and on a share slow enough that the time
    /// for sampling is up once the demuxer first reads, which then samples only where a
    /// segment would be larger than 256 MB.
    @MainActor
    @Test("a file over 256 MB starts playing before all its keyframes are listed", arguments: [false, true])
    func largeFileStartsBeforeItsKeyframesAreListed(timeRunsOut: Bool) async throws {
        let reader = try PaddedRecording()
        let clock = TestClock()
        let opening = Task { try await DeliveredFile.start(reading: reader, named: "recording.ts", clock: clock) }
        if timeRunsOut {
            // The probe's look, then the demuxer's first.
            await reader.awaitReads(2)
            clock.advance(by: .milliseconds(2500))
        }
        let file = try await opening.value
        let readToOpen = reader.bytesRead
        let segments = try await file.segmentSeconds(of: "v.m3u8")
        let played = try await PlayedFile(file)
        let fromStart = await played.framesShown(for: .seconds(3))
        let afterSeek = await played.framesShown(from: 40.5, for: .seconds(2))
        await played.stop()

        #expect(reader.size > 256 << 20)
        #expect(readToOpen < reader.size / (timeRunsOut ? 3 : 1), "\(readToOpen >> 20) MB of \(reader.size >> 20) MB read to open")
        // Thirty keyframes two seconds apart, half of them 2 MB apart.
        #expect(segments.count < 30, "\(segments)")
        #expect(abs(segments.reduce(0, +) - 60) < 0.1, "\(segments)")
        #expect(fromStart.count > 48, "\(fromStart)")
        #expect(fromStart.first?.number == 0)
        #expect(fromStart.filter { !$0.isTheSourceFrameForItsTime }.isEmpty, "\(fromStart)")
        #expect(afterSeek.first?.number == 972, "\(afterSeek)")
        #expect(afterSeek.filter { !$0.isTheSourceFrameForItsTime }.isEmpty, "\(afterSeek)")
    }

    @Test("stopping a bridged delivery while a read is stuck returns within 2 s, and stopping it again does nothing")
    func stopWhileAReadIsStuck() async throws {
        let clock = TestClock()
        let reader = try PaddedRecording()
        let file = try await DeliveredFile.start(reading: reader, named: "recording.ts", clock: clock)
        let segments = try await file.segmentSeconds(of: "v.m3u8")
        reader.wedgeReads()
        let fetch = Task { try? await file.bytes("v-\(segments.count / 2).m4s") }
        await reader.awaitWedgedRead()

        let stop = Task { await file.stop() }
        try await clock.waitForSleep(dueIn: .seconds(2))
        clock.advance(by: .seconds(2))
        await stop.value
        await file.stop()

        #expect(clock.pendingSleeps.isEmpty, "\(clock.pendingSleeps)")
        fetch.cancel()
        reader.release()
    }

    /// A read that fails before the segment's first fragment is ready, and one that fails after
    /// it was sent. A segment there is 16 MB of the file, and its first second 8 MB.
    @Test("when a segment's read fails partway, AVPlayer gets a response it cannot mistake for a whole segment",
          arguments: [(4 << 20, "HTTP/1.1 500 Internal Server Error"), (12 << 20, "HTTP/1.1 200 OK")])
    func segmentReadFailingPartway(failingAfter bytes: Int, startsAs status: String) async throws {
        let reader = try PaddedRecording()
        let file = try await DeliveredFile.start(reading: reader, named: "recording.ts", clock: TestClock())
        // The first segment past the opening read, in the part of the file 16 MB a keyframe.
        let path = "v-2.m4s"
        let whole = try await file.bytes(path)
        await file.stop()

        let failing = try PaddedRecording()
        let delivery = try await DeliveredFile.start(reading: failing, named: "recording.ts", clock: TestClock())
        failing.failReads(after: bytes)
        let url = delivery.url(of: path)
        let request = "GET \(url.path) HTTP/1.1\r\nHost: \(url.host() ?? "")\r\nConnection: close\r\n\r\n"
        let response = try await rawHTTPExchange(with: url, sending: Data(request.utf8), timeout: .seconds(30))
        await delivery.stop()

        let head = String(decoding: response.prefix(while: { $0 != 0x0D }), as: UTF8.self)
        #expect(head == status)
        #expect(response.count < whole.count, "\(response.count) bytes of a \(whole.count)-byte segment")
        #expect(!response.suffix(5).elementsEqual(Data("0\r\n\r\n".utf8)), "the response ended as a whole one")
    }
    /// What a fresh delivery of `reader` reads to serve `path`: how many bytes, and how far into
    /// the file.
    private static func reads(fetching path: String, from reader: PaddedRecording) async throws -> (bytes: Int, furthest: Int) {
        let file = try await DeliveredFile.start(reading: reader, named: "recording.ts", clock: TestClock())
        let before = reader.bytesRead
        _ = reader.takeFurthest()
        _ = try await file.bytes(path)
        let read = (reader.bytesRead - before, reader.takeFurthest())
        await file.stop()
        return read
    }

    /// A delivery of the padded recording whose reads past the last 4 MB of `v-2` wait, and a
    /// client asking for that segment.
    private static func segmentRequestHeldShortOfItsEnd() async throws -> (DeliveredFile, PaddedRecording, SocketClient) {
        let end = try await reads(fetching: "v-2.m4s", from: PaddedRecording()).furthest
        let reader = try PaddedRecording()
        let file = try await DeliveredFile.start(reading: reader, named: "recording.ts", clock: TestClock())
        reader.wedgeReads(reachingPast: end - (4 << 20))
        let url = file.url(of: "v-2.m4s")
        let client = try SocketClient(url)
        client.send("GET \(url.path) HTTP/1.1\r\nHost: x\r\n\r\n")
        return (file, reader, client)
    }

    private static func hasAFragment(_ data: Data) -> Bool { WireResponse.all(in: data).first?.chunks.isEmpty == false }

    /// `v-2` is 16 MB of the file, and a fragment holds a second of it.
    @Test("the first fragment of a segment is handed over before the segment's last packet is read")
    func firstFragmentComesBeforeTheSegmentIsRead() async throws {
        let (file, reader, client) = try await Self.segmentRequestHeldShortOfItsEnd()
        let received = await client.receive(timeout: .seconds(10), until: Self.hasAFragment)
        reader.release()
        await file.stop()

        #expect(Self.hasAFragment(received.data), "no fragment came before the segment's last 4 MB were read")
    }

    @Test("a segment read cancelled after its first fragment fetches at most one more read, and returns")
    func cancelledSegmentStopsItsRead() async throws {
        let (file, reader, client) = try await Self.segmentRequestHeldShortOfItsEnd()
        try #require(Self.hasAFragment(await client.receive(timeout: .seconds(10), until: Self.hasAFragment).data))
        await reader.awaitWedgedRead()
        client.closeSending()
        try #require(await client.receive(timeout: .seconds(5)).closed)
        let readsWhenLetGo = reader.readsStarted
        reader.release()
        await file.stop()

        #expect(reader.readsStarted == readsWhenLetGo, "\(reader.readsStarted - readsWhenLetGo) reads after the client went")
    }

    /// Sixty numbered seconds with a keyframe every ten and MP2 audio, which is converted, padded
    /// to 20 MB a keyframe. A span's audio and its video come from the same stretch of the file.
    @Test("a converted audio segment reads half a second ahead of its span, not the whole span before it")
    func convertedAudioReadsLittleBeforeItsSpan() async throws {
        func recording() throws -> PaddedRecording {
            try PaddedRecording(transportStream: BridgeFixture.data("numbered-mp2-long-gop.ts"), packetSize: 188, padding: .halves(170, 170))
        }
        let video = try await Self.reads(fetching: "v-2.m4s", from: recording()).bytes
        let audio = try await Self.reads(fetching: "a0-2.m4s", from: recording()).bytes

        #expect(audio < video + video / 2, "\(audio >> 20) MB read for the audio, \(video >> 20) MB for the video")
    }
}
