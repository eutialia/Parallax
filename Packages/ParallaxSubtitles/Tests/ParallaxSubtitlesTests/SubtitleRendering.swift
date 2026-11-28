import CoreGraphics
import Foundation
import ParallaxSubtitles
import Testing

/// The bytes of a file under `Fixtures/`, as a server or a share would hand them over.
func fixture(_ path: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(path)", withExtension: nil), "no fixture \(path)")
    return try Data(contentsOf: url)
}

let hdCanvas = CGSize(width: 1280, height: 720)

/// A fixture loaded the way a player loads a subtitle: format from the file's extension,
/// storage equal to the canvas unless given.
struct LoadedSubtitle {
    let renderer: SubtitleRenderer
    let canvas: CGSize
    let storage: CGSize

    /// What is drawn at `seconds`. The canvas is set again first, as an overlay does on
    /// layout, so the renderer hands back the frame even when it looks like the last one.
    func drawing(at seconds: Double) async throws -> Drawing {
        await renderer.setCanvas(size: canvas, scale: 1, storageSize: storage)
        let frame = try #require(await renderer.frame(at: seconds), "no frame at \(seconds) s")
        return Drawing(frame: frame, pixels: try frame.image.map(rendered))
    }

    func setStyle(_ style: SubtitleStyleOverride?) async {
        await renderer.setStyleOverride(style)
    }
}

func loaded(
    _ path: String,
    languageHint: String? = nil,
    fontFamily: String = SubtitleRenderer.standardFontFamily,
    style: SubtitleStyleOverride? = nil,
    canvas: CGSize = hdCanvas,
    storage: CGSize? = nil
) async throws -> LoadedSubtitle {
    let renderer = SubtitleRenderer(defaultFontFamily: fontFamily)
    await renderer.setStyleOverride(style)
    try await renderer.load(try fixture(path), format: try format(of: path), languageHint: languageHint)
    return LoadedSubtitle(renderer: renderer, canvas: canvas, storage: storage ?? canvas)
}

func format(of path: String) throws -> SubtitleSourceFormat {
    switch (path as NSString).pathExtension {
    case "srt": .srt
    case "vtt": .vtt
    case "ass": .ass
    default: throw FixtureError.unknownExtension(path)
    }
}

enum FixtureError: Error {
    case unknownExtension(String)
}

/// The frame a renderer draws at one moment, with its pixels read back.
struct Drawing: Equatable {
    let frame: SubtitleFrame
    let pixels: RenderedPixels?

    static func == (lhs: Drawing, rhs: Drawing) -> Bool {
        lhs.frame.imageRect == rhs.frame.imageRect && lhs.pixels?.rows == rhs.pixels?.rows
    }

    var isBlank: Bool { pixels == nil }

    /// The canvas pixel at `(x, y)`; transparent outside the drawn rect.
    func pixel(x: Int, y: Int) -> RenderedPixels.Pixel {
        let origin = frame.imageRect.origin
        let local = (x: x - Int(origin.x), y: y - Int(origin.y))
        guard let pixels, local.x >= 0, local.y >= 0, local.x < pixels.width, local.y < pixels.height else {
            return RenderedPixels.Pixel(blue: 0, green: 0, red: 0, alpha: 0)
        }
        return pixels[local.x, local.y]
    }

    /// The canvas box of every pixel `hit` accepts, nil when none is.
    func box(where hit: (RenderedPixels.Pixel) -> Bool = { $0.alpha >= 8 }) -> CGRect? {
        guard let pixels, let local = pixels.bounds(where: { hit(pixels[$0, $1]) }) else { return nil }
        return CGRect(
            x: frame.imageRect.minX + CGFloat(local.minX), y: frame.imageRect.minY + CGFloat(local.minY),
            width: CGFloat(local.maxX - local.minX + 1), height: CGFloat(local.maxY - local.minY + 1)
        )
    }

    /// The ink, ring included.
    var ink: CGRect? { box() }

    /// The near-white glyph fill, without the ring around it.
    var fillCount: Int { pixels?.fill.count ?? 0 }

    /// Every canvas pixel of the columns `columns`, top to bottom, so two drawings of lines
    /// that start at the same place can be compared on their first glyphs alone.
    func columns(_ columns: Range<Int>, rows: Range<Int>? = nil) -> [UInt32] {
        (rows ?? 0..<Int(frame.canvasSize.height)).flatMap { y in
            columns.map { x in
                let pixel = pixel(x: x, y: y)
                return UInt32(pixel.alpha) << 24 | UInt32(pixel.red) << 16 | UInt32(pixel.green) << 8 | UInt32(pixel.blue)
            }
        }
    }
}

/// The drawing of the cue at `seconds` of a fixture, loaded on its own.
func drawing(
    of path: String,
    at seconds: Double,
    languageHint: String? = nil,
    fontFamily: String = SubtitleRenderer.standardFontFamily,
    style: SubtitleStyleOverride? = nil,
    canvas: CGSize = hdCanvas
) async throws -> Drawing {
    try await loaded(path, languageHint: languageHint, fontFamily: fontFamily, style: style, canvas: canvas)
        .drawing(at: seconds)
}

extension RenderedPixels {
    /// The pixel bytes row by row, without the padding a row may carry past its width.
    var rows: [ArraySlice<UInt8>] {
        (0..<height).map { bytes[($0 * bytesPerRow)..<($0 * bytesPerRow + width * 4)] }
    }
}

extension RenderedPixels: Equatable {
    static func == (lhs: RenderedPixels, rhs: RenderedPixels) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height && lhs.rows == rhs.rows
    }
}
