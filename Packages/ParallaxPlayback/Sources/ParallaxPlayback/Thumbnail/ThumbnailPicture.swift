import AetherLibavcodec
import AetherLibavutil
import AetherLibswscale
import CoreGraphics
import Foundation

extension MediaDemuxer {
    /// The first picture the video's decoder gives from the keyframe nearest `time` that a seek
    /// finds, as `readVideo(fromKeyframeNear:into:)` reads it, sized and coloured as a tile shows
    /// it.
    func picture(near time: Int64) throws -> CGImage {
        let stream = streams[videoStream]
        let decode = try FirstPicture(stream)
        try readVideo(fromKeyframeNear: time, into: decode)
        try decode.finish()
        guard let picture = decode.picture else { throw MediaThumbnailer.Failure.noPicture }
        return picture
    }
}

/// Decodes a video's packets until the decoder gives a picture.
///
/// Lives on one thread: the demuxer's queue that reads the packets.
private final class FirstPicture: PacketSink {
    private let decoder: VideoDecoder
    private let parameters: CodecParameters
    private(set) var picture: CGImage?

    init(_ stream: DemuxedStream) throws {
        decoder = try VideoDecoder(stream.parameters, timedByDecodeOrder: stream.packetTimes == .decodeOnly)
        parameters = stream.parameters
    }

    var isCancelled: Bool { Task.isCancelled }
    var isSatisfied: Bool { picture != nil }

    func accept(_ packet: MediaPacket) throws {
        try decoder.decode(packet, into: keep)
    }

    /// The pictures the decoder still holds, when the read ended short of one.
    func finish() throws {
        if picture == nil { try decoder.finish(into: keep) }
    }

    private func keep(_ frame: UnsafePointer<AVFrame>) throws {
        guard picture == nil else { return }
        picture = try TilePicture.image(of: frame, in: parameters)
    }
}

/// A decoded picture as a tile shows it: at most `ThumbnailSize.maximumHeight` tall, at the
/// shape and the way up it is shown at, and in SDR.
enum TilePicture {
    enum Failure: Error {
        case scaler
        case image
    }

    static func image(of frame: UnsafePointer<AVFrame>, in parameters: CodecParameters) throws -> CGImage {
        let source = parameters.pointer.pointee
        let aspect = frame.pointee.sample_aspect_ratio.num > 0 ? frame.pointee.sample_aspect_ratio : source.sample_aspect_ratio
        let turns = quarterTurns(of: frame)
        let size = ThumbnailSize(
            width: Int(frame.pointee.width), height: Int(frame.pointee.height),
            pixelAspect: aspect.num > 0 && aspect.den > 0 ? Double(aspect.num) / Double(aspect.den) : 1,
            turnedAQuarter: turns % 2 == 1)
        let transfer = frame.pointee.color_trc == AVCOL_TRC_UNSPECIFIED ? source.color_trc : frame.pointee.color_trc
        let hdr: CFString? = switch transfer {
        case AVCOL_TRC_SMPTE2084: CGColorSpace.itur_2100_PQ
        case AVCOL_TRC_ARIB_STD_B67: CGColorSpace.itur_2100_HLG
        default: nil
        }
        let matrix = frame.pointee.colorspace == AVCOL_SPC_UNSPECIFIED ? source.color_space : frame.pointee.colorspace
        let range = frame.pointee.color_range == AVCOL_RANGE_UNSPECIFIED ? source.color_range : frame.pointee.color_range
        let pixels = try rgb(
            of: frame, size: size, sixteenBit: hdr != nil, matrix: matrix, fullRange: range == AVCOL_RANGE_JPEG)
        let image = if let hdr {
            try cgImage(pixels, size: size, bitsPerComponent: 16, space: CGColorSpace(name: hdr),
                        info: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        } else {
            try cgImage(pixels, size: size, bitsPerComponent: 8, space: CGColorSpace(name: CGColorSpace.sRGB),
                        info: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        }
        guard hdr != nil || turns != 0 else { return image }
        return try drawnUpright(image, size: size, turns: turns)
    }

    /// Counterclockwise quarter turns the picture is shown at: a phone's video is stored as the
    /// sensor saw it, with a display matrix that turns it upright. The decoder copies the
    /// stream's matrix onto every frame.
    private static func quarterTurns(of frame: UnsafePointer<AVFrame>) -> Int {
        guard let side = av_frame_get_side_data(frame, AV_FRAME_DATA_DISPLAYMATRIX), side.pointee.size >= 36 else {
            return 0
        }
        let degrees = av_display_rotation_get(UnsafeRawPointer(side.pointee.data).assumingMemoryBound(to: Int32.self))
        guard degrees.isFinite else { return 0 }
        return (Int((degrees / 90).rounded()) % 4 + 4) % 4
    }

    /// Packed BGRA, or 16-bit RGBA for a picture tone-mapped after, at the tile's size.
    private static func rgb(
        of frame: UnsafePointer<AVFrame>, size: ThumbnailSize, sixteenBit: Bool, matrix: AVColorSpace, fullRange: Bool
    ) throws -> Data {
        let format = sixteenBit ? AV_PIX_FMT_RGBA64LE : AV_PIX_FMT_BGRA
        guard let scaler = sws_getContext(
            frame.pointee.width, frame.pointee.height, AVPixelFormat(rawValue: frame.pointee.format),
            Int32(size.scaled.width), Int32(size.scaled.height), format, Int32(SWS_AREA.rawValue), nil, nil, nil)
        else { throw Failure.scaler }
        defer { sws_freeContext(scaler) }
        let coefficients = sws_getCoefficients(Int32(matrix.rawValue))
        sws_setColorspaceDetails(scaler, coefficients, fullRange ? 1 : 0, coefficients, 1, 0, 1 << 16, 1 << 16)

        let rowBytes = size.scaled.width * (sixteenBit ? 8 : 4)
        var pixels = Data(count: rowBytes * size.scaled.height)
        let sourcePlanes: [UnsafePointer<UInt8>?] = [
            UnsafePointer(frame.pointee.data.0), UnsafePointer(frame.pointee.data.1),
            UnsafePointer(frame.pointee.data.2), UnsafePointer(frame.pointee.data.3),
        ]
        let sourceStrides = [
            frame.pointee.linesize.0, frame.pointee.linesize.1, frame.pointee.linesize.2, frame.pointee.linesize.3,
        ]
        let rows = pixels.withUnsafeMutableBytes { buffer in
            let planes: [UnsafeMutablePointer<UInt8>?] = [buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), nil, nil, nil]
            return sws_scale(scaler, sourcePlanes, sourceStrides, 0, frame.pointee.height, planes, [Int32(rowBytes), 0, 0, 0])
        }
        guard rows == Int32(size.scaled.height) else { throw Failure.scaler }
        return pixels
    }

    private static func cgImage(
        _ pixels: Data, size: ThumbnailSize, bitsPerComponent: Int, space: CGColorSpace?, info: UInt32
    ) throws -> CGImage {
        guard let space, let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                width: size.scaled.width, height: size.scaled.height, bitsPerComponent: bitsPerComponent,
                bitsPerPixel: bitsPerComponent * 4, bytesPerRow: pixels.count / size.scaled.height, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        else { throw Failure.image }
        return image
    }

    /// The picture turned upright and drawn into SDR. An HDR picture is tone-mapped by
    /// CoreGraphics' default, as Photos shows one on an SDR screen: its reference white at about
    /// three quarters of SDR white, its highlights rolled off above it.
    private static func drawnUpright(_ image: CGImage, size: ThumbnailSize, turns: Int) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: size.shown.width, height: size.shown.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw Failure.image }
        let (width, height) = (CGFloat(size.shown.width), CGFloat(size.shown.height))
        switch turns {
        case 1: context.translateBy(x: width, y: 0)
        case 2: context.translateBy(x: width, y: height)
        case 3: context.translateBy(x: 0, y: height)
        default: break
        }
        context.rotate(by: CGFloat(turns) * .pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.scaled.width, height: size.scaled.height))
        guard let drawn = context.makeImage() else { throw Failure.image }
        return drawn
    }
}

/// The size a tile's picture is stored at: as tall as the picture is shown up to
/// `maximumHeight`, and as wide as it is shown at that height.
struct ThumbnailSize {
    /// The browse tiles' height in pixels, and what the cache's budget per thumbnail is sized
    /// for.
    static let maximumHeight = 320

    /// The decoded picture's size once scaled, before it is turned upright.
    let scaled: (width: Int, height: Int)
    /// The stored thumbnail's size: `scaled`, turned.
    let shown: (width: Int, height: Int)

    /// `pixelAspect` is a stored pixel's width over its height. `turnedAQuarter` is whether the
    /// picture is shown turned on its side.
    init(width: Int, height: Int, pixelAspect: Double, turnedAQuarter: Bool = false) {
        let stored = (width: Double(width) * pixelAspect, height: Double(max(height, 1)))
        let upright = turnedAQuarter ? (width: stored.height, height: stored.width) : stored
        let shownHeight = max(min(Int(upright.height.rounded()), Self.maximumHeight), 1)
        let shownWidth = max(Int((upright.width * Double(shownHeight) / upright.height).rounded()), 1)
        shown = (shownWidth, shownHeight)
        scaled = turnedAQuarter ? (shownHeight, shownWidth) : shown
    }
}
