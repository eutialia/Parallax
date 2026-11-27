import CoreGraphics
import Foundation
import Synchronization
import Testing
import ParallaxCoreTestSupport
import ParallaxTestScaling
import ParallaxCore
import ParallaxPlaybackTestSupport
@testable import ParallaxPlayback

@Suite("MediaThumbnailer", .scaledTimeLimit())
struct MediaThumbnailerTests {
    /// The numbered fixtures run at 24 pictures a second with a keyframe every 48, so 5% into a
    /// 12 s file is the keyframe at the start and 5% into a minute is the one at 2 s. An MPG's
    /// and a TS's seek lands on a packet before 5%, and the first keyframe read from there is the
    /// one after it.
    @Test("a WMV, an AVI, an FLV and an MKV without cover art each get a thumbnail of their picture at the keyframe at or before 5% in, and an MPG and a TS, which carry no index, at most one keyframe past it",
          arguments: [
            ("numbered-wmv2.asf", 0), ("numbered-mpeg4.avi", 0), ("numbered-h264.mpg", 48),
            ("numbered-mpeg2-open-gop.ts", 96), ("numbered-flv1.flv", 0), ("numbered-h264-silent.mkv", 48),
          ])
    func everyContainerGetsAThumbnail(file: String, keyframe: Int) async throws {
        let picture = try await TilePixels(Self.thumbnail(file))
        #expect(picture.number == keyframe, "\(picture.levels(rowsAboveTheMiddle: 0))")
    }

    @Test("each of those thumbnails carries the file's length", arguments: [
        ("numbered-wmv2.asf", 12.0), ("numbered-mpeg4.avi", 12), ("numbered-h264.mpg", 12),
        ("numbered-mpeg2-open-gop.ts", 60), ("numbered-flv1.flv", 12), ("numbered-h264-silent.mkv", 60),
    ])
    func thumbnailsCarryTheFileLength(file: String, seconds: Double) async throws {
        let length = try #require(try await Self.thumbnail(file).duration)
        #expect(abs(length.fractionalSeconds - seconds) < 0.1, "\(length)")
    }

    @Test("an MP4 whose audio AVPlayer cannot play gets a thumbnail")
    func mp4WithUnplayableAudioGetsAThumbnail() async throws {
        let picture = try await TilePixels(Self.thumbnail("numbered-h264-dts.mp4"))
        #expect(picture.number == 0)
    }

    @Test("an AV1 MP4 and a 10-bit H.264 MP4 get a thumbnail", arguments: ["numbered-av1.mp4", "numbered-h264-high10.mp4"])
    func av1AndHigh10GetAThumbnail(file: String) async throws {
        let picture = try await TilePixels(Self.thumbnail(file))
        #expect(picture.number == 0)
    }

    /// The fixture weaves picture 0 into the top field and picture 1 into the bottom one, each on
    /// its own rows.
    @Test("an interlaced file's thumbnail is one whole picture, not two fields woven together")
    func interlacedThumbnailIsOnePicture() async throws {
        let picture = try await TilePixels(Self.thumbnail("numbered-interlaced-h264.ts"))
        let middle = try #require(picture.number)
        #expect(picture.number(rowsAboveTheMiddle: 1) == middle)
    }

    /// The squares are lit at reference white. Read as SDR, without tone mapping, a PQ file's
    /// come out at 58% grey.
    @Test("an HDR file's thumbnail is tone-mapped to SDR, its reference white at three quarters of SDR white",
          arguments: ["numbered-hdr-pq.mkv", "numbered-hdr-hlg.mkv"])
    func hdrIsToneMapped(file: String) async throws {
        let picture = try await TilePixels(Self.thumbnail(file))
        #expect(!picture.isHDR)
        #expect(picture.number == 48, "\(picture.levels(rowsAboveTheMiddle: 0))")
        let lit = picture.levels(rowsAboveTheMiddle: 0).enumerated().filter { 48 & (1 << $0.offset) != 0 }.map(\.element)
        #expect(lit.allSatisfy { (184...192).contains($0) }, "\(lit)")
    }

    /// The cover is 300 by 450 in one flat colour, and the video 160 by 90.
    @Test("an MP4 or an MKV with cover art gets that picture as its thumbnail, not a frame",
          arguments: ["numbered-h264-cover.mp4", "numbered-h264-cover.mkv"])
    func coverArtIsTheThumbnail(file: String) async throws {
        let picture = try await TilePixels(Self.thumbnail(file))
        try #require(picture.size.width == 300 && picture.size.height == 450, "\(picture.size)")
        let (red, green, blue) = picture.colour(x: 150, y: 225)
        #expect(abs(red - 0xC0) <= 8 && abs(green - 0x30) <= 8 && abs(blue - 0x20) <= 8, "\((red, green, blue))")
    }

    @Test("a thumbnail from cover art carries the file's length",
          arguments: [("numbered-h264-cover.mp4", 12.0), ("numbered-h264-cover.mkv", 60)])
    func coverCarriesTheFileLength(file: String, seconds: Double) async throws {
        let length = try #require(try await Self.thumbnail(file).duration)
        #expect(abs(length.fractionalSeconds - seconds) < 0.1, "\(length)")
    }

    @Test("an MKV's fonts are not read for its thumbnail")
    func fontsAreNotRead() async throws {
        // The same video without the fonts. Looking for a cover still reads each font's header,
        // and the reads come in whole blocks, so what the fonts add is a fraction of them, not
        // none; reading their data would add all of them.
        let fontsData = try BridgeFixture.data("numbered-h264-fonts")
        let silentData = try BridgeFixture.data("numbered-h264-silent")
        let withFonts = CountingReader(fontsData)
        let without = CountingReader(silentData)
        let picture = try await TilePixels(MediaThumbnailer().thumbnail(of: withFonts))
        _ = try await MediaThumbnailer().thumbnail(of: without)
        #expect(picture.number == 48)
        let fonts = fontsData.count - silentData.count
        #expect(withFonts.bytesRead - without.bytesRead < fonts / 4,
                "read \(withFonts.bytesRead) bytes with \(fonts) of fonts, \(without.bytesRead) without")
    }

    @Test("the thumbnail of a WMV and of an open-GOP MPEG-2 file is the whole numbered picture, not decoder grey filler",
          arguments: [("numbered-wmv2.asf", 0), ("numbered-mpeg2-open-gop.ts", 96)])
    func noGreyFiller(file: String, keyframe: Int) async throws {
        let picture = try await TilePixels(Self.thumbnail(file))
        #expect(picture.number == keyframe, "\(picture.levels(rowsAboveTheMiddle: 0))")
    }

    @Test("an MP4 that AVPlayer plays gets a thumbnail 320 tall, with its width following the aspect ratio")
    func thumbnailIs320Tall() async throws {
        let source = try await OversizedThumbnailSource.make()
        defer { source.cleanup() }
        let reader = InMemoryRandomAccessReader(data: try Data(contentsOf: source.url))
        let picture = try await TilePixels(MediaThumbnailer().thumbnail(of: reader))
        // 640 by 480 is 4:3. Allow a one-pixel round-off on the derived width.
        #expect(picture.size.height == 320)
        #expect(abs(picture.size.width - 426) <= 1, "\(picture.size)")
    }

    @Test("a file in no container the app knows gets no thumbnail, and the reason is given", arguments: [
        ("ogg-vp8.ogg", MediaDemuxer.OpenFailure.unbridgedContainer(name: "ogg")),
    ])
    func unknownContainerIsRefused(file: String, reason: MediaDemuxer.OpenFailure) async throws {
        await #expect(throws: reason) { try await Self.thumbnail(file) }
    }

    /// 160 by 90 stored, each pixel a third wider than tall: 213 by 90 as shown.
    @Test("a file whose pixels are not square gets a thumbnail at the shape it is shown at")
    func nonSquarePixelsKeepTheShownShape() async throws {
        let picture = try await TilePixels(Self.thumbnail("anamorphic.mkv"))
        #expect(picture.size.height == 90 && abs(picture.size.width - 213) <= 1, "\(picture.size)")
    }

    /// A screen of tiles asks for many at once, and a device has few cores to run them on.
    @Test("thumbnails asked for at once, twice as many as the device has cores, all arrive")
    func thumbnailsAskedForAtOnceAllArrive() async throws {
        let count = 2 * ProcessInfo.processInfo.activeProcessorCount
        let sizes = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<count { group.addTask { try await Self.thumbnail("anamorphic.mkv").data.count } }
            return try await group.reduce(into: [Int]()) { $0.append($1) }
        }
        #expect(sizes.count == count && sizes.allSatisfy { $0 > 0 })
    }

    /// Each stored 160 by 90, with a display matrix that turns it counterclockwise by the
    /// quarters given.
    @Test("a video recorded in portrait or upside down gets an upright thumbnail", arguments: [
        ("numbered-h264-rotated-90.mp4", 1, 90, 160), ("numbered-h264-rotated-180.mp4", 2, 160, 90),
        ("numbered-h264-rotated-270.mp4", 3, 90, 160),
    ])
    func turnedVideoIsUpright(file: String, quarters: Int, width: Int, height: Int) async throws {
        let picture = try await TilePixels(Self.thumbnail(file))
        try #require(picture.size.width == width && picture.size.height == height, "\(picture.size)")
        #expect(picture.number(turnedQuarters: quarters) == 48)
    }

    /// The share answers the open's first read only once the grab has been cancelled. The cover
    /// is what a grab that missed the cancellation would hand back.
    @Test("a grab whose caller is cancelled stops and throws a cancellation")
    func cancelledGrabThrows() async throws {
        let reader = ParkedReader(try BridgeFixture.data("numbered-h264-cover.mkv"))
        let grab = Task { try await MediaThumbnailer().thumbnail(of: reader) }
        await reader.firstRead()
        grab.cancel()
        reader.answer()
        await #expect(throws: CancellationError.self) { try await grab.value }
    }

    // MARK: - Property tests

    @Test("a thumbnail is as tall as its source is shown, up to 320, and keeps the shape it is shown at, upright")
    func thumbnailSizeKeepsTheShownShape() {
        var random = SeededGenerator(seed: 0x7468_756D_6273)
        for _ in 0..<2_000 {
            let width = Int.random(in: 2...8_192, using: &random)
            let height = Int.random(in: 2...4_320, using: &random)
            let pixelAspect = [1, 4.0 / 3, 3.0 / 4, 64.0 / 45, 32.0 / 27, 8.0 / 9].randomElement(using: &random)!
            let turned = Bool.random(using: &random)
            let size = ThumbnailSize(width: width, height: height, pixelAspect: pixelAspect, turnedAQuarter: turned)
            let shownWidth = Double(width) * pixelAspect
            let (uprightWidth, uprightHeight) = turned ? (Double(height), shownWidth) : (shownWidth, Double(height))
            let input = "\(width)×\(height) at \(pixelAspect), turned \(turned)"
            #expect(size.shown.height == min(Int(uprightHeight.rounded()), 320), "\(input) gave \(size.shown)")
            let widthForShape = uprightWidth / uprightHeight * Double(size.shown.height)
            // A picture too narrow for one pixel at that height is kept one pixel wide.
            #expect(abs(Double(size.shown.width) - max(widthForShape, 1)) <= 1, "\(input) gave \(size.shown)")
            #expect(turned ? size.scaled == (size.shown.height, size.shown.width) : size.scaled == size.shown)
        }
    }

    @Test("a thumbnail is taken at or after the file's start and before its end")
    func thumbnailTimeIsInsideTheFile() {
        var random = SeededGenerator(seed: 0x706F_7369_7469)
        for _ in 0..<2_000 {
            let start = Int64.random(in: -10_000_000_000...100_000_000_000_000, using: &random)
            let duration = Int64.random(in: 1...1_000_000_000_000_000, using: &random)
            let time = ThumbnailPosition.time(start: start, duration: duration)
            #expect(time >= start && time < start + duration, "\(start) + \(duration) gave \(time)")
        }
    }

    // MARK: - Helpers

    private static func thumbnail(_ file: String) async throws -> ThumbnailFrame {
        let reader = InMemoryRandomAccessReader(data: try BridgeFixture.data(file))
        return try await MediaThumbnailer().thumbnail(of: reader)
    }
}

/// A thumbnail's pixels, as a tile shows them.
private struct TilePixels {
    let size: (width: Int, height: Int)
    private let rgba: [UInt8]

    /// Whether the stored picture is in an HDR space, to be tone-mapped wherever it is shown.
    let isHDR: Bool

    init(_ frame: ThumbnailFrame) throws {
        let image = try #require(decodeThumbnailImage(frame.data))
        size = (image.width, image.height)
        isHDR = image.colorSpace.map(CGColorSpaceUsesITUR_2100TF) ?? false
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        try #require(drawn)
        rgba = pixels
    }

    func colour(x: Int, y: Int) -> (Int, Int, Int) {
        let at = (y * size.width + x) * 4
        return (Int(rgba[at]), Int(rgba[at + 1]), Int(rgba[at + 2]))
    }

    /// The green of each of the 16 squares a numbered fixture draws, 10 pixels wide, on the
    /// middle row or a row above it.
    func levels(rowsAboveTheMiddle: Int) -> [Int] {
        (0..<16).map { colour(x: $0 * 10 + 5, y: size.height / 2 - rowsAboveTheMiddle).1 }
    }

    /// The number the picture carries, lowest bit on the left. Nil when a square is neither
    /// dark nor light, as grey filler is.
    var number: Int? { number(rowsAboveTheMiddle: 0) }

    /// The number of a picture shown turned `quarters` counterclockwise from the way it was drawn.
    func number(turnedQuarters quarters: Int) -> Int? {
        let (width, height) = size
        let levels = (0..<16).map { square in
            let along = square * 10 + 5
            return switch quarters {
            case 1: colour(x: width / 2, y: height - 1 - along).1
            case 2: colour(x: width - 1 - along, y: height - 1 - height / 2).1
            case 3: colour(x: width - 1 - width / 2, y: along).1
            default: colour(x: along, y: height / 2).1
            }
        }
        guard levels.allSatisfy({ $0 < 64 || $0 > 160 }) else { return nil }
        return levels.enumerated().reduce(0) { $0 | ($1.element > 160 ? 1 << $1.offset : 0) }
    }

    func number(rowsAboveTheMiddle: Int) -> Int? {
        let levels = levels(rowsAboveTheMiddle: rowsAboveTheMiddle)
        guard levels.allSatisfy({ $0 < 64 || $0 > 160 }) else { return nil }
        return levels.enumerated().reduce(0) { $0 | ($1.element > 160 ? 1 << $1.offset : 0) }
    }
}

/// A fixture's bytes on a share whose first read answers only when told to.
private final class ParkedReader: RandomAccessReading {
    private let data: InMemoryRandomAccessReader
    private let parked = Atomic(false)
    private let asked: (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation)
    private let answered: (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation)

    init(_ data: Data) {
        self.data = InMemoryRandomAccessReader(data: data)
        asked = AsyncStream.makeStream()
        answered = AsyncStream.makeStream()
    }

    var fileSize: UInt64 { get async throws { try await data.fileSize } }

    func read(offset: UInt64, length: Int) async throws -> Data {
        if !parked.exchange(true, ordering: .relaxed) {
            asked.continuation.yield()
            for await _ in answered.stream { break }
        }
        return try await data.read(offset: offset, length: length)
    }

    /// Returns once the first read has arrived.
    func firstRead() async {
        for await _ in asked.stream { break }
    }

    func answer() { answered.continuation.yield() }
}

