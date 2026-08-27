import CoreGraphics
import Foundation
import Testing

@testable import ParallaxSubtitles

// MARK: - Converted SRT fixtures

enum SRTFixture {
    /// One SRT cue running 1s–3s — the shape most render-path probes need.
    static func text(_ body: String) -> String {
        "1\n00:00:01,000 --> 00:00:03,000\n\(body)\n"
    }

    static func data(text: String) -> Data {
        Data(Self.text(text).utf8)
    }
}

/// A family that is installed on every Apple device and is NOT in the bundle —
/// the probe for "no system font is reachable". With ASS_FONTPROVIDER_NONE a
/// script naming it must fall through to `default_family`.
let unreachableSystemFamily = "PingFang SC"

// MARK: - Authored ASS fixtures

enum ASSFixture {

    static let playResX = 640
    static let playResY = 360

    /// An ASS script with one cue from 1s to 3s, authored against a 640x360 canvas.
    ///
    /// - Parameters:
    ///   - text: the Dialogue text field, override tags included.
    ///   - primaryColour: ASS `&HAABBGGRR` literal for the fill.
    ///   - outline: border width; zero keeps the probe's pixels purely the fill colour.
    static func script(
        text: String,
        fontName: String = "Arial",
        primaryColour: String = "&H00FFFFFF",
        outline: Double = 0,
        playResX: Int = ASSFixture.playResX,
        playResY: Int = ASSFixture.playResY,
        fontSize: Int = 28
    ) -> String {
        """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: \(playResX)
        PlayResY: \(playResY)
        WrapStyle: 0
        ScaledBorderAndShadow: yes
        YCbCr Matrix: None

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,\(fontName),\(fontSize),\(primaryColour),&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,\(outline),0,2,20,20,20,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,\(text)

        """
    }

    static func data(
        text: String,
        fontName: String = "Arial",
        primaryColour: String = "&H00FFFFFF",
        outline: Double = 0,
        playResX: Int = ASSFixture.playResX,
        playResY: Int = ASSFixture.playResY,
        fontSize: Int = 28
    ) -> Data {
        Data(script(
            text: text, fontName: fontName, primaryColour: primaryColour, outline: outline,
            playResX: playResX, playResY: playResY, fontSize: fontSize
        ).utf8)
    }
}

/// A renderer wired to the 640x360 probe canvas.
func makeProbeRenderer(fontFamily: String = SubtitleRenderer.standardFontFamily) async -> SubtitleRenderer {
    let renderer = SubtitleRenderer(defaultFontFamily: fontFamily)
    await renderer.setCanvas(
        size: CGSize(width: ASSFixture.playResX, height: ASSFixture.playResY),
        scale: 1,
        storageSize: CGSize(width: ASSFixture.playResX, height: ASSFixture.playResY)
    )
    return renderer
}

// MARK: - Pixel inspection

/// The raw bytes behind a rendered `CGImage`, read without going back through
/// CoreGraphics so that what is asserted is exactly what the blend produced.
struct RenderedPixels {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: [UInt8]

    /// Premultiplied BGRA, the layout the blend writes.
    struct Pixel {
        var blue: UInt8
        var green: UInt8
        var red: UInt8
        var alpha: UInt8
    }

    subscript(x: Int, y: Int) -> Pixel {
        let offset = y * bytesPerRow + x * 4
        return Pixel(
            blue: bytes[offset],
            green: bytes[offset + 1],
            red: bytes[offset + 2],
            alpha: bytes[offset + 3]
        )
    }

    var all: [Pixel] {
        (0..<height).flatMap { y in (0..<width).map { x in self[x, y] } }
    }

    /// Pixels that are close to fully covered — the body of a glyph rather than
    /// its antialiased fringe.
    var opaque: [Pixel] { all.filter { $0.alpha > 200 } }
}

/// Alpha at a point in CANVAS coordinates, so two frames of different sizes can
/// be compared at the same place on screen. Points outside the frame's drawn
/// rect read as fully transparent, which is what the compositor would show.
func alpha(of frame: SubtitleFrame, atCanvas point: CGPoint) throws -> UInt8 {
    guard let image = frame.image, frame.imageRect.contains(point) else { return 0 }
    let pixels = try rendered(image)
    return pixels[Int(point.x - frame.imageRect.minX), Int(point.y - frame.imageRect.minY)].alpha
}

/// Share of the drawn rect that is near-fully opaque.
func opaqueFraction(of frame: SubtitleFrame) throws -> Double {
    guard let image = frame.image else { return 0 }
    let pixels = try rendered(image)
    return Double(pixels.opaque.count) / Double(pixels.width * pixels.height)
}

func rendered(_ image: CGImage) throws -> RenderedPixels {
    let provider = try #require(image.dataProvider)
    let data = try #require(provider.data) as Data
    return RenderedPixels(
        width: image.width,
        height: image.height,
        bytesPerRow: image.bytesPerRow,
        bytes: [UInt8](data)
    )
}

// MARK: - Script inspection

/// The `Dialogue:` lines of a generated script, without the `Dialogue: ` prefix.
func dialogueLines(_ script: String) -> [String] {
    script
        .split(separator: "\n")
        .filter { $0.hasPrefix("Dialogue: ") }
        .map { String($0.dropFirst("Dialogue: ".count)) }
}

/// The Text field of a Dialogue line — everything after the ninth comma.
func dialogueText(_ line: String) -> String {
    let fields = line.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
    return fields.count == 10 ? String(fields[9]) : ""
}

/// `(start, end, text)` for every cue in a generated script.
func cues(_ script: String) -> [(start: String, end: String, text: String)] {
    dialogueLines(script).map { line in
        let fields = line.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
        return (String(fields[1]), String(fields[2]), dialogueText(line))
    }
}

// MARK: - libass diagnostics

/// The font-selection lines of a captured libass log. Every resolution libass
/// makes is reported here and nowhere else — a glyph nobody could supply still
/// renders as a perfectly valid tofu box.
func fontSelectLines(_ log: [String]) -> [String] {
    log.filter { $0.contains("fontselect:") }
}

/// Whether any fontselect line reports a request for `family` being served.
func selected(_ family: String, in log: [String]) -> Bool {
    fontSelectLines(log).contains { $0.contains("(\(family),") }
}
