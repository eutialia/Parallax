import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encoded stills shaped like what a thumbnailer hands back, built in code so the tests carry no
/// binary fixtures. 320×180, PNG.
enum TestFrames {
    /// A decoder's mid-GOP output: the grey (YUV 128) reference it substitutes for the missing
    /// keyframe, with low-amplitude residual noise in most blocks and a few saturated blocks where
    /// intra macroblocks landed. Shaped after libavcodec's wmv2 decode of a stream cut mid-GOP.
    static let mosaic = png { x, y in
        let block = (x / 8) * 131 + (y / 8) * 71
        if block % 23 == 0 { return (255, 0, 255) }
        if block % 29 == 0 { return (0, 220, 0) }
        let noise = (x * 7 + y * 13) % 13 - 6
        let grey = 130 + noise
        return (grey, grey, grey)
    }

    /// A lit frame: colour bars under a diagonal luma ramp, with hard edges between the bars.
    static let scene = png { x, y in
        let bars = [(220, 40, 40), (40, 200, 60), (230, 210, 30), (30, 60, 220), (200, 40, 200)]
        let bar = bars[x * bars.count / width]
        let ramp = Double(x + y) / Double(width + height)
        return (Int(Double(bar.0) * ramp), Int(Double(bar.1) * ramp), Int(Double(bar.2) * ramp))
    }

    /// The same frame at a fifth of its brightness: a night scene, which must pass.
    static let dark = png { x, y in
        let bar = 40 + 30 * ((x * 5 / width) % 2)
        let ramp = Double(x + y) / Double(width + height)
        return (Int(Double(bar) * ramp), Int(Double(bar / 2) * ramp), Int(Double(bar) * ramp))
    }

    /// A black leader frame, which must pass.
    static let black = png { _, _ in (0, 0, 0) }

    private static let width = 320
    private static let height = 180

    private static func png(_ pixel: (Int, Int) -> (Int, Int, Int)) -> Data {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let i = (y * width + x) * 4
                bytes[i] = UInt8(clamping: r)
                bytes[i + 1] = UInt8(clamping: g)
                bytes[i + 2] = UInt8(clamping: b)
                bytes[i + 3] = 255
            }
        }
        let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
