import CoreGraphics
import Foundation
import ImageIO

/// A colour as hue/saturation/brightness, each 0...1 — the currency both halves of the
/// accent pipeline speak. Extraction produces one straight off the pixels; normalization
/// repairs it for the scrim. Keeping the two stages in the same value type is what lets
/// each be tested on its own, without a `CGImage` in sight for the half that doesn't need one.
public nonisolated struct AccentHSB: Equatable, Sendable {
    public var hue: Double
    public var saturation: Double
    public var brightness: Double

    public init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }
}

/// Derives the player's accent hue from the playing item's artwork.
///
/// The pipeline is three pure steps, deterministic end to end: decode a small thumbnail,
/// find the artwork's dominant hue by chroma-weighted voting, then normalize that hue into
/// something that survives sitting on a bright-white video scrim. Every step is a static
/// function on values, so the interesting behavior (a muddy poster lifted into the legible band,
/// a black-and-white film falling back to white) is a unit test rather than a device session.
///
/// System frameworks only (CoreGraphics/ImageIO) — no SwiftUI, no `Color` — which is why it
/// lives here rather than beside the player: the app target keeps only the `Color` bridge and
/// the view model that runs this. `nonisolated` throughout, and the whole thing is pure
/// arithmetic over `Data`/`CGImage`, so the caller is free to run it wherever it likes; the
/// player runs it off the main thread, once per item, and leaves the bar white until — and
/// unless — it answers.
public nonisolated enum ArtworkAccent {

    // MARK: - Tuning

    /// Longest edge of the decoded thumbnail. Big enough that a poster's subject still
    /// occupies real area after the server's own scaling, small enough that the decode is
    /// microseconds. The accent is a *hue*, not a colour match — more pixels buy nothing.
    public static let thumbnailMaxPixel = 64
    /// The voting grid. 16×16 = 256 votes, which is plenty to separate a poster's key colour
    /// from its background without any of this showing up in a time profile.
    public static let sampleSide = 16
    /// Hue bins, 24° apart. Coarse on purpose: a poster's sky is a gradient of a dozen blues, and
    /// they have to pool into one candidate instead of splitting their coverage across bins where
    /// a single flat patch could beat any one of them.
    public static let hueBuckets = 15

    /// Pixels darker than this (a poster's letterbox, a night scene's shadows) or brighter than
    /// this (blown highlights, white type) carry no trustworthy hue and are dropped before the
    /// vote — their hue is quantization noise, and there are a lot of them.
    public static let shadowFloor = 0.10
    public static let highlightCeiling = 0.96

    /// Below this, the dominant hue is indistinguishable from grey: a black-and-white film, a
    /// monochrome poster, a sepia scan with almost no chroma. There is no accent to be had, and
    /// inventing one from noise would paint a different colour on every episode of the same
    /// show. Nil here IS the white fallback.
    public static let graySaturationFloor = 0.12

    /// The scrim contract, and it is a FLOOR-first one. The accent is drawn over video at 30-60%
    /// opacity as a glow, an outline, and a thin tint band: under this brightness it disappears
    /// into the footage, under this saturation it stops being a hue at all. The band is wide
    /// because the point of the accent is that it looks like the poster — clamping hard enough to
    /// pastelize everything makes every film resolve to the same three washes. The ceiling only
    /// catches neon, and the brightness floor only lifts what would otherwise be invisible.
    public static let brightnessFloor = 0.70
    public static let saturationFloor = 0.35
    public static let saturationCeiling = 0.75

    // MARK: - Pipeline

    /// The whole derivation: encoded artwork bytes → the accent to paint with, or nil for
    /// "leave it white". The one entry point the view model calls.
    public static func accent(fromImageData data: Data) -> AccentHSB? {
        guard let image = thumbnail(from: data) else { return nil }
        return accent(in: image)
    }

    /// `CGImage → accent`. Split from the decode so a test can hand it an image it drew itself.
    public static func accent(in image: CGImage) -> AccentHSB? {
        dominant(in: image).flatMap(normalized)
    }

    /// The artwork's dominant hue, by chroma-weighted vote over a downsampled grid.
    ///
    /// The weight is saturation, LINEARLY, and the linearity is the load-bearing part: a bin's
    /// score is the chromatic area it covers, so what wins is the colour the poster is mostly
    /// made of. Vividness still counts — a grey pixel votes with nothing and a pure one votes
    /// with all it has — but it counts once, as a multiplier on coverage, not as its own
    /// contest. Squaring it (which this used to do) made a vivid tenth of the frame outscore a
    /// muted seven-tenths, and the bar came back a colour nobody would name looking at the
    /// poster. What keeps the honest average from being mud isn't the exponent, it's the
    /// brightness gates below: a poster's dead ground is its shadows and its blown highlights,
    /// and those never reach the ballot.
    ///
    /// Artwork with no chroma anywhere falls through to the plain mean, whose saturation is ~0
    /// and which `normalized` therefore rejects. That keeps the "this has no colour" verdict in
    /// exactly one place instead of splitting it across both stages.
    public static func dominant(in image: CGImage) -> AccentHSB? {
        guard let pixels = downsample(image) else { return nil }

        var buckets = [HueVote](repeating: .zero, count: hueBuckets)
        var meanR = 0.0, meanG = 0.0, meanB = 0.0
        var counted = 0.0

        for start in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[start + 3]) / 255
            guard alpha > 0.5 else { continue }
            // The buffer is premultiplied; un-premultiply so a semi-transparent logo edge
            // votes with its own colour instead of a darkened one.
            let r = Double(pixels[start]) / 255 / alpha
            let g = Double(pixels[start + 1]) / 255 / alpha
            let b = Double(pixels[start + 2]) / 255 / alpha
            meanR += r; meanG += g; meanB += b
            counted += 1

            let hsb = hsb(red: min(r, 1), green: min(g, 1), blue: min(b, 1))
            guard hsb.brightness >= shadowFloor, hsb.brightness <= highlightCeiling else { continue }
            let weight = hsb.saturation
            guard weight > 0 else { continue }

            let index = min(Int(hsb.hue * Double(hueBuckets)), hueBuckets - 1)
            let angle = hsb.hue * 2 * .pi
            buckets[index].weight += weight
            buckets[index].x += cos(angle) * weight
            buckets[index].y += sin(angle) * weight
            buckets[index].saturation += hsb.saturation * weight
            buckets[index].brightness += hsb.brightness * weight
        }

        guard counted > 0 else { return nil }
        let plain = hsb(red: meanR / counted, green: meanG / counted, blue: meanB / counted)

        guard let winner = buckets.max(by: { $0.weight < $1.weight }), winner.weight > 0 else {
            return plain
        }
        // Circular mean, so the bin straddling red's 0/1 wrap averages to red rather than to
        // the cyan exactly opposite it.
        var hue = atan2(winner.y, winner.x) / (2 * .pi)
        if hue < 0 { hue += 1 }
        return AccentHSB(hue: hue,
                         saturation: winner.saturation / winner.weight,
                         brightness: winner.brightness / winner.weight)
    }

    /// Repairs an extracted hue for the scrim it has to live on, or rejects it.
    ///
    /// Two rules, and they are the reason this is separable from the pixels:
    /// - Too little chroma to name a colour → nil, and the bar stays its monochrome white.
    /// - Otherwise the hue is kept EXACTLY and only its saturation/brightness are clamped into
    ///   the legible band — a deep muddy maroon comes back as a lighter red of the same hue. The
    ///   band is deliberately loose: this is a legibility repair, not a restyling, and the accent
    ///   has to still look like the poster it came out of.
    public static func normalized(_ hsb: AccentHSB) -> AccentHSB? {
        guard hsb.saturation >= graySaturationFloor else { return nil }
        return AccentHSB(
            hue: hsb.hue,
            saturation: min(max(hsb.saturation, saturationFloor), saturationCeiling),
            brightness: min(max(hsb.brightness, brightnessFloor), 1)
        )
    }

    // MARK: - Pure colour math

    /// RGB → HSB, on 0...1 components. Hand-rolled rather than routed through `UIColor` so it
    /// is a pure function of three doubles: no colour space to resolve, no trait environment,
    /// and testable without a running app.
    public static func hsb(red: Double, green: Double, blue: Double) -> AccentHSB {
        let high = max(red, green, blue)
        let low = min(red, green, blue)
        let chroma = high - low
        guard chroma > 0 else { return AccentHSB(hue: 0, saturation: 0, brightness: high) }

        let sextant: Double
        switch high {
        case red: sextant = (green - blue) / chroma
        case green: sextant = 2 + (blue - red) / chroma
        default: sextant = 4 + (red - green) / chroma
        }
        var hue = sextant / 6
        if hue < 0 { hue += 1 }
        return AccentHSB(hue: hue, saturation: chroma / high, brightness: high)
    }

    // MARK: - Decode

    /// ImageIO's own scaler, which decodes straight to the size we want instead of decoding a
    /// full poster and throwing 99% of it away.
    private static func thumbnail(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixel,
        ] as CFDictionary)
    }

    /// Redraws any image into one fixed sRGB grid, which is what makes the vote deterministic:
    /// the input's own colour space, orientation, and pixel format stop mattering here.
    private static func downsample(_ image: CGImage) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: sampleSide * sampleSide * 4)
        let drew = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: buffer.baseAddress, width: sampleSide, height: sampleSide,
                      bitsPerComponent: 8, bytesPerRow: sampleSide * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleSide, height: sampleSide))
            return true
        }
        return drew ? bytes : nil
    }

    /// One hue bin's running tally. The x/y pair is the circular sum the mean is read off.
    private struct HueVote {
        var weight = 0.0
        var x = 0.0
        var y = 0.0
        var saturation = 0.0
        var brightness = 0.0
        static let zero = HueVote()
    }
}
