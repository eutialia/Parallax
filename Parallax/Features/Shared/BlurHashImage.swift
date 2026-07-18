import SwiftUI

/// BlurHash placeholder support.
///
/// Jellyfin ships a compact BlurHash string alongside every image (see `ImageRef.blurHash`). A
/// BlurHash encodes a handful of cosine components — enough to reconstruct a smooth, blurred
/// impression of the artwork in ~20-30 characters. Decoding it into the loading placeholder means a
/// poster cell shows a soft colour field that matches the incoming image instead of a flat gray box,
/// so a scrolling grid reads as "artwork settling in" rather than "empty boxes filling up".
///
/// The decoder here is the standard public-domain reference algorithm (base83 → DC/AC cosine
/// components → sRGB/linear gamma → small pixel grid), kept dependency-free. Everything renders to a
/// deliberately tiny raster: it is a blur, so extra pixels buy nothing but cost cache memory.

// MARK: - Decoder

/// Pure-Swift BlurHash decoder. Stateless; all entry points are static. Malformed input never
/// crashes — every length/range check returns `nil` so a corrupt hash degrades to the flat
/// placeholder rather than trapping.
enum BlurHashDecoder {
    /// The 83-character alphabet BlurHash packs its integers into (order is significant — it defines
    /// each glyph's digit value).
    private static let base83 =
        Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")

    /// Decodes `hash` into a small `UIImage`, sized so its long edge is `longEdge` points and the
    /// short edge follows `aspectRatio` (width ÷ height). Returns `nil` for any malformed hash.
    static func image(from hash: String, aspectRatio: CGFloat, longEdge: CGFloat = 32) -> UIImage? {
        let ratio = aspectRatio > 0 ? aspectRatio : 1
        let width: Int
        let height: Int
        if ratio >= 1 {
            width = max(1, Int(longEdge.rounded()))
            height = max(1, Int((longEdge / ratio).rounded()))
        } else {
            height = max(1, Int(longEdge.rounded()))
            width = max(1, Int((longEdge * ratio).rounded()))
        }
        guard let cg = cgImage(from: hash, width: width, height: height) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// The unpacked cosine field: component counts plus every (linear-RGB) coefficient. Shared by
    /// the raster decode (placeholders) and the mesh sampler (the animated floor bleed) so the two
    /// consumers can't drift on the parse.
    private static func components(from hash: String) -> (numX: Int, numY: Int, colours: [(Float, Float, Float)])? {
        // A valid hash is at least 6 chars (size flag + max-AC + DC) and each AC term adds 2 chars.
        guard hash.count >= 6 else { return nil }
        let chars = Array(hash)

        guard let sizeFlag = decode83(chars, 0, 1) else { return nil }
        let numY = sizeFlag / 9 + 1
        let numX = sizeFlag % 9 + 1
        // The reference range is 1...9 components per axis; anything else is corrupt.
        guard (1...9).contains(numX), (1...9).contains(numY) else { return nil }

        // Expected length: 1 (size) + 1 (max AC) + 4 (DC) + 2 per remaining component.
        guard hash.count == 4 + 2 * numX * numY else { return nil }

        guard let quantisedMax = decode83(chars, 1, 2) else { return nil }
        let maxValue = Float(quantisedMax + 1) / 166

        var colours = [(Float, Float, Float)](repeating: (0, 0, 0), count: numX * numY)
        for i in 0..<colours.count {
            if i == 0 {
                guard let value = decode83(chars, 2, 6) else { return nil }
                colours[0] = decodeDC(value)
            } else {
                let from = 4 + i * 2
                guard let value = decode83(chars, from, from + 2) else { return nil }
                colours[i] = decodeAC(value, maximumValue: maxValue)
            }
        }
        return (numX, numY, colours)
    }

    /// Evaluates the hash's cosine field at one continuous point of the unit square (0,0 = top
    /// leading), returning linear RGB. The continuous form of the raster loop's per-pixel basis.
    private static func field(
        _ colours: [(Float, Float, Float)], numX: Int, numY: Int, x: Float, y: Float
    ) -> (Float, Float, Float) {
        var r: Float = 0, g: Float = 0, b: Float = 0
        for j in 0..<numY {
            for i in 0..<numX {
                let basis = cos(Float.pi * x * Float(i)) * cos(Float.pi * y * Float(j))
                let colour = colours[i + j * numX]
                r += colour.0 * basis
                g += colour.1 * basis
                b += colour.2 * basis
            }
        }
        return (r, g, b)
    }

    /// A hash parsed ONCE and held for repeated continuous sampling — the animated floor bleed's
    /// per-tick colour source. The base83 decode happens in `meshField(from:)`; after that each
    /// `colors` call is just `columns × rows` cosine-field evaluations (microseconds), cheap enough
    /// to run inside a 20 fps `TimelineView` tick. Value type on purpose: SwiftUI can hold it in a
    /// `let` computed per body without identity games.
    struct MeshField {
        fileprivate let numX: Int
        fileprivate let numY: Int
        fileprivate let colours: [(Float, Float, Float)]

        /// Samples the colour field on a `columns × rows` grid for a `MeshGradient` (row-major,
        /// matching the mesh's colour order). Rows sample artwork-y from `yStart` (first row) to
        /// `yEnd` (last row) — the floor bleed passes a DESCENDING span (e.g. 1.0 → 0.6) for the
        /// mirrored read: the artwork's bottom colours on the mesh's first row, walking back up the
        /// image with depth. `rowXOffsets` shifts each row's horizontal sampling window (one offset
        /// per row; `nil` = resting alignment; rows past the array's end rest at 0 rather than
        /// trapping — the caller's row count and drift table are declared independently) — THE
        /// animation input: drifting the offsets makes the field's colour features themselves
        /// travel along the strip. Out-of-range x needs no clamping: the cosine basis is even and
        /// 2-periodic, so sampling past [0, 1] continues the field as its own mirror image — a
        /// drifting window never hits a wall or a seam. `columns`/`rows` must satisfy the consuming
        /// `MeshGradient`'s own >= 2 contract; this sampler just fills whatever grid is asked of it.
        func colors(columns: Int, rows: Int, yStart: Float, yEnd: Float, rowXOffsets: [Float]? = nil) -> [Color] {
            var out: [Color] = []
            out.reserveCapacity(columns * rows)
            for row in 0..<rows {
                let ty = rows > 1 ? Float(row) / Float(rows - 1) : 0
                let y = yStart + (yEnd - yStart) * ty
                let xOffset = rowXOffsets.map { row < $0.count ? $0[row] : 0 } ?? 0
                for col in 0..<columns {
                    let x = (columns > 1 ? Float(col) / Float(columns - 1) : 0) + xOffset
                    let (r, g, b) = BlurHashDecoder.field(colours, numX: numX, numY: numY, x: x, y: y)
                    out.append(Color(
                        red: Double(BlurHashDecoder.linearToSRGBFloat(r)),
                        green: Double(BlurHashDecoder.linearToSRGBFloat(g)),
                        blue: Double(BlurHashDecoder.linearToSRGBFloat(b))
                    ))
                }
            }
            return out
        }
    }

    /// Parses `hash` into a reusable `MeshField`. Malformed hash = `nil`, same contract as the
    /// raster decode.
    static func meshField(from hash: String) -> MeshField? {
        guard let (numX, numY, colours) = components(from: hash) else { return nil }
        return MeshField(numX: numX, numY: numY, colours: colours)
    }

    /// Decodes `hash` into a `width × height` RGBA `CGImage` by evaluating the cosine field per
    /// output pixel.
    static func cgImage(from hash: String, width: Int, height: Int) -> CGImage? {
        guard let (numX, numY, colours) = components(from: hash) else { return nil }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 255, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                var r: Float = 0, g: Float = 0, b: Float = 0
                for j in 0..<numY {
                    for i in 0..<numX {
                        let basis = cos(Float.pi * Float(x) * Float(i) / Float(width))
                                  * cos(Float.pi * Float(y) * Float(j) / Float(height))
                        let colour = colours[i + j * numX]
                        r += colour.0 * basis
                        g += colour.1 * basis
                        b += colour.2 * basis
                    }
                }
                let offset = y * bytesPerRow + x * 4
                pixels[offset]     = linearToSRGB(r)
                pixels[offset + 1] = linearToSRGB(g)
                pixels[offset + 2] = linearToSRGB(b)
                pixels[offset + 3] = 255
            }
        }

        let colourSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: colourSpace, bitmapInfo: bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    // MARK: Component decoding

    /// DC term packs a full 24-bit sRGB colour; unpack each channel and linearise.
    private static func decodeDC(_ value: Int) -> (Float, Float, Float) {
        (sRGBToLinear(value >> 16), sRGBToLinear((value >> 8) & 255), sRGBToLinear(value & 255))
    }

    /// AC terms pack three signed magnitudes in base-19, scaled by `maximumValue`.
    private static func decodeAC(_ value: Int, maximumValue: Float) -> (Float, Float, Float) {
        let r = value / (19 * 19)
        let g = (value / 19) % 19
        let b = value % 19
        return (signPow((Float(r) - 9) / 9, 2) * maximumValue,
                signPow((Float(g) - 9) / 9, 2) * maximumValue,
                signPow((Float(b) - 9) / 9, 2) * maximumValue)
    }

    /// Signed power — preserves the sign while raising the magnitude, so negative AC lobes survive.
    private static func signPow(_ value: Float, _ exp: Float) -> Float {
        copysign(pow(abs(value), exp), value)
    }

    // MARK: base83 + gamma

    /// Decodes characters `[from, to)` of `chars` as a base-83 integer; `nil` on any glyph outside
    /// the alphabet or an out-of-bounds range.
    private static func decode83(_ chars: [Character], _ from: Int, _ to: Int) -> Int? {
        guard from >= 0, to <= chars.count, from < to else { return nil }
        var value = 0
        for index in from..<to {
            guard let digit = base83.firstIndex(of: chars[index]) else { return nil }
            value = value * 83 + digit
        }
        return value
    }

    private static func sRGBToLinear(_ value: Int) -> Float {
        let v = Float(value) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func linearToSRGBFloat(_ value: Float) -> Float {
        let v = max(0, min(1, value))
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    private static func linearToSRGB(_ value: Float) -> UInt8 {
        UInt8((linearToSRGBFloat(value) * 255).rounded())
    }
}

// MARK: - Cache

/// Process-wide decode cache keyed by the hash string. A scrolling grid re-visits the same hashes
/// as cells recycle; without a cache every appearance re-runs the (cheap but non-free) cosine
/// evaluation. `NSCache` gives us memory-pressure eviction for free. The cache key folds in the
/// requested long-edge so a hero-sized decode and a tile-sized decode of the same hash don't clash.
final class BlurHashImageCache {
    static let shared = BlurHashImageCache()
    private let cache = NSCache<NSString, UIImage>()

    /// Returns the decoded image for `hash`/`aspectRatio`, decoding + caching on a miss. Decoding a
    /// ~12-component grid at 32px is sub-millisecond, so this stays synchronous — no async churn for
    /// a placeholder that must be on-screen the instant the cell appears. The key folds in the
    /// aspect too: the same item's hash backs a 2:3 poster cell and a 16:9 band, and those decode
    /// different rasters — one shared key would serve whichever shape decoded first to both.
    func image(for hash: String, aspectRatio: CGFloat, longEdge: CGFloat) -> UIImage? {
        // Aspect keyed at 1/1000 precision as a plain Int — `String(format:)` here allocated a
        // formatter pass on EVERY probe, including warm hits from long-lived placeholders.
        let key = "\(hash)@\(Int(longEdge.rounded()))@\(Int((aspectRatio * 1000).rounded()))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = BlurHashDecoder.image(
            from: hash, aspectRatio: aspectRatio, longEdge: longEdge
        ) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

// MARK: - View

/// Renders a decoded BlurHash as a placeholder — or the flat `Color.artworkPlaceholder` when the
/// hash is malformed. Drawn behind the real artwork by `MediaImage`, it pins the cell's box and the
/// loaded image crossfades on top. Works identically on iOS and tvOS (`UIImage` is the shared
/// currency; nothing here touches iOS-only API).
///
/// LAYOUT-NEUTRAL BY CONSTRUCTION: the layout element is a `Color` — flexible in both axes, tiny
/// ideal size — exactly like the flat placeholder this view replaces; the decoded image is painted
/// as a clipped overlay that can never answer a layout proposal. A bare `.resizable().fill` image
/// here once let the raster's own shape leak into `MediaImage`'s boxed/fill sizing under width-only
/// proposals — posters squared off, hero bands inflated past the screen, shelf tiles stretched
/// (device-reproduced 2026-07-18). The blur is paint, never geometry.
struct BlurHashPlaceholder: View {
    let hash: String
    /// The box shape the blur will back (width ÷ height), used only to pick the decode raster's
    /// proportions so the overlay's cover-crop discards nothing meaningful. NOT a layout input.
    var aspectRatio: CGFloat = MediaImage.poster
    /// Long-edge resolution to decode at. 32pt is plenty — it is a blur, so more pixels only cost
    /// cache memory.
    var longEdge: CGFloat = 32

    var body: some View {
        Color.artworkPlaceholder
            .overlay {
                if let image = BlurHashImageCache.shared.image(
                    for: hash, aspectRatio: aspectRatio, longEdge: longEdge
                ) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .accessibilityIgnoresInvertColors()
                }
            }
            .clipped()
    }
}

#if DEBUG
#Preview("BlurHash vs flat placeholder") {
    // Known-good sample hashes (from the BlurHash reference set) so the visual win is inspectable
    // without a live server: each poster box compares a decoded blur against the flat gray fill.
    let hashes = [
        "LEHLh[WB2yk8pyoJadR*.7kCMdnj",
        "LGF5]+Yk^6#M@-5c,1J5@[or[Q6.",
        "L6Pj0^jE.AyE_3t7t7R**0o#DgR4",
        "LKO2?U%2Tw=w]~RBVZRi};RPxuwH",
    ]
    return VStack(spacing: 16) {
        HStack(spacing: 12) {
            posterBox { Color.artworkPlaceholder }
            ForEach(hashes, id: \.self) { hash in
                posterBox { BlurHashPlaceholder(hash: hash) }
            }
        }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.background)
}

@ViewBuilder
private func posterBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .frame(width: 110)
        .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
}

/// Layout-neutrality regression proof — the 2026-07-18 device breakage. Reproduces `MediaImage`'s
/// `.boxed` composition (`placeholder.overlay{}.aspectRatio(_, .fit)`) under a WIDTH-ONLY proposal
/// (plain VStack, no height constraint): exactly where a placeholder with intrinsic geometry let the
/// decoded raster dictate the box (posters squared, cells inflated). Every tile here must render at
/// its labeled aspect — a square "2:3" tile means the leak is back. The renders-only harness never
/// caught it because previews without a server exercise the flat-Color branch alone.
#Preview("BlurHash · boxed layout proof", traits: .fixedLayout(width: 560, height: 420)) {
    let hash = "LGF5]+Yk^6#M@-5c,1J5@[or[Q6."
    HStack(alignment: .top, spacing: 20) {
        ForEach(
            [("2:3 poster", 2.0 / 3.0), ("16:9 landscape", 16.0 / 9.0), ("1:1 square", 1.0)],
            id: \.0
        ) { label, ratio in
            VStack(spacing: 8) {
                BlurHashPlaceholder(hash: hash, aspectRatio: ratio)
                    .overlay { EmptyView() }
                    .aspectRatio(ratio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                    .frame(width: 150)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Color.secondaryLabel)
            }
        }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color.background)
}
#endif
