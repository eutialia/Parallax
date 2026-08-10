import UIKit
import Nuke

/// Crops a transparent PNG to its opaque bounding box before display. Jellyfin logo assets
/// routinely bake large transparent margins into the canvas, so two logos given the same layout
/// box rendered at wildly different visual sizes — the margin, not the mark, was driving the
/// aspect fit. Trimming first means the layout box always fits the MARK, which is what
/// normalizes the hero logos to a similar visual size.
///
/// Runs in the Nuke pipeline, not the view layer, on purpose: `identifier` keys the
/// processed-image cache, so the alpha scan happens once per logo (off the main thread) and
/// every later display gets the cropped bitmap for free.
struct LogoAlphaTrim: ImageProcessing {
    /// Alpha above this (0–255) counts as content. Tolerant of antialiased edges and soft
    /// glows without letting a near-invisible watermark pin the crop to the full canvas.
    /// BUMP `identifier` when tuning this or `margin` — they're baked into cached results.
    private static let threshold: UInt8 = 16
    /// Breathing room kept around the detected box, in source pixels — a hard crop at the
    /// exact bounding box clips the outermost antialiased column of the mark.
    private static let margin = 2
    /// Fail-open ceiling: the raster comes from the server, which need not honor the request's
    /// `maxWidth` — a hostile or broken origin could return an enormous canvas, and the scan
    /// allocates 4 bytes/pixel. Past the ceiling the logo just ships untrimmed.
    private static let maxPixels = 16_000_000

    var identifier: String { "parallax.logo-alpha-trim.v1" }

    func process(_ image: PlatformImage) -> PlatformImage? {
        guard let cg = image.cgImage else { return image }
        let width = cg.width, height = cg.height
        // Per-dimension bounds BEFORE the product, so a hostile header can't overflow the
        // multiplication on its way to the ceiling check.
        guard width > 2, height > 2,
              width <= Self.maxPixels, height <= Self.maxPixels,
              width * height <= Self.maxPixels else { return image }

        // RGBA8 raster (an alpha-only context needs a NULL color space, which the Swift
        // initializer can't express); the scan reads every 4th byte — the alpha channel.
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return image }

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width where pixels[row + x * 4 + 3] > Self.threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        // Fully transparent, or already tight — nothing to do.
        guard maxX >= minX, maxY >= minY else { return image }
        let box = CGRect(
            x: max(0, minX - Self.margin),
            y: max(0, minY - Self.margin),
            width: min(width, maxX + 1 + Self.margin) - max(0, minX - Self.margin),
            height: min(height, maxY + 1 + Self.margin) - max(0, minY - Self.margin)
        )
        guard box.width < CGFloat(width) || box.height < CGFloat(height) else { return image }

        guard let cropped = cg.cropping(to: box) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }
}
