import CoreGraphics
import Foundation
import ParallaxCore

/// Encoded stills shaped like what a thumbnailer hands back, built in code so the tests carry no
/// binary fixtures. 320×180, encoded by `ImageTranscode.encodeHEIC` as the thumbnailers do.
enum TestFrames {
    /// A decoder's mid-GOP output: the grey (YUV 128) reference it substitutes for the missing
    /// keyframe, untouched where nothing moved, with the P-frames' residuals and a few saturated
    /// intra blocks clustered where the motion was. Shaped after libavcodec's wmv2 decode of a
    /// stream cut mid-GOP.
    static let mosaic = frame { x, y in
        guard y >= height * 2 / 3 else { return (130, 130, 130) }
        let block = (x / 8) * 131 + (y / 8) * 71
        if block % 7 == 0 { return (255, 0, 255) }
        if block % 11 == 0 { return (0, 220, 0) }
        let residual = (x * 7 + y * 13) % 61 - 30
        return (130 + residual, 130 - residual, 130 + residual / 2)
    }

    /// A lit frame: colour bars under a diagonal luma ramp, with hard edges between the bars.
    static let scene = frame { x, y in
        let bars = [(220, 40, 40), (40, 200, 60), (230, 210, 30), (30, 60, 220), (200, 40, 200)]
        let bar = bars[x * bars.count / width]
        let ramp = Double(x + y) / Double(width + height)
        return (Int(Double(bar.0) * ramp), Int(Double(bar.1) * ramp), Int(Double(bar.2) * ramp))
    }

    /// The same frame at a fifth of its brightness: a night scene, which must pass.
    static let dark = frame { x, y in
        let bar = 40 + 30 * ((x * 5 / width) % 2)
        let ramp = Double(x + y) / Double(width + height)
        return (Int(Double(bar) * ramp), Int(Double(bar / 2) * ramp), Int(Double(bar) * ramp))
    }

    /// A black-and-white shot in fog: a neutral grey sky fading towards the horizon over a dark
    /// shore. Most of it is mid-grey, none of it is the filler's single level. Must pass.
    static let fog = frame { x, y in
        let sky = 146 - 30 * y / height
        let shore = y > height * 3 / 4 ? 40 : 0
        let ripple = (x * 5 + y * 3) % 9 - 4
        let grey = sky - shore + ripple
        return (grey, grey, grey)
    }

    /// A black leader frame, which must pass.
    static let black = frame { _, _ in (0, 0, 0) }

    private static let width = 320
    private static let height = 180

    private static func frame(_ pixel: (Int, Int) -> (Int, Int, Int)) -> Data {
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
        return try! ImageTranscode.encodeHEIC(context.makeImage()!)
    }
}
