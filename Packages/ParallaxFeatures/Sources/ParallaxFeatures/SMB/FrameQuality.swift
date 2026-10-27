import CoreGraphics
import Foundation
import ParallaxCore

/// Tells a real video frame from a decoder's grey filler.
///
/// A decode that starts mid-GOP has no reference frame, and libavcodec (VLC's decoder for wmv3)
/// substitutes one painted YUV 128: neutral mid-grey, about RGB 130 after range expansion. The
/// P-frames that follow only add their residuals to it, so the snapshot is a grey field with sparse
/// blocks of detail.
///
/// The test is "mostly the filler's one grey level", not "low contrast" or "mid-grey": a black
/// leader and a night scene are as flat as the filler, and a black-and-white shot in fog is as
/// grey. Measured at 32 px on mid-GOP decodes by libavcodec's wmv2, msmpeg4v3, mpeg4, mpeg2 and
/// h264 decoders, HEIC-encoded as the thumbnailers do, 60–91% of pixels sit within 2 of RGB 130.
/// Desaturated photographs pushed into fog reach 32% at most, though up to 90% of them sit within
/// 16 of neutral grey.
nonisolated enum FrameQuality {
    /// False for undecodable bytes or a frame that is mostly the decoder's grey filler.
    static func isUsable(_ data: Data) -> Bool {
        guard let fraction = fillerGreyFraction(data) else { return false }
        return fraction < 0.5
    }

    /// The share of pixels within 2 of RGB (130, 130, 130) on every channel, measured on a
    /// 32 px downscale; nil when `data` doesn't decode.
    private static func fillerGreyFraction(_ data: Data) -> Double? {
        guard let image = ImageTranscode.downscaledImage(from: data, maxPixelSize: 32),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let (width, height) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let filler = stride(from: 0, to: pixels.count, by: 4).count { i in
            pixels[i..<i + 3].allSatisfy { abs(Int($0) - 130) <= 2 }
        }
        return Double(filler) / Double(width * height)
    }
}
