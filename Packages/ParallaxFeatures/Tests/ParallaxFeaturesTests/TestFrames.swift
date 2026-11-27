import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An encoded still shaped like what a thumbnailer hands back, built in code so the tests carry no
/// binary fixtures. 320×180, as JPEG: what a thumbnailer hands back on a host with no HEVC encoder.
enum TestFrames {
    /// A lit frame: colour bars under a diagonal luma ramp, with hard edges between the bars.
    static let scene = frame { x, y in
        let bars = [(220, 40, 40), (40, 200, 60), (230, 210, 30), (30, 60, 220), (200, 40, 200)]
        let bar = bars[x * bars.count / width]
        let ramp = Double(x + y) / Double(width + height)
        return (Int(Double(bar.0) * ramp), Int(Double(bar.1) * ramp), Int(Double(bar.2) * ramp))
    }

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
        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return encoded as Data
    }
}
