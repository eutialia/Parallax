import CoreGraphics
import Foundation
import ParallaxSubtitles
import Testing

// MARK: - Pixel inspection

/// The raw bytes behind a rendered `CGImage`, read without going back through
/// CoreGraphics so that what is asserted is exactly what the blend produced.
struct RenderedPixels {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: [UInt8]

    /// Premultiplied BGRA, the layout the blend writes.
    struct Pixel: Equatable {
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

    /// The glyph fill: 92% white over a black ring, so the colour channels — not
    /// the alpha, which the ring also raises — identify it.
    static func isFill(_ pixel: Pixel) -> Bool { pixel.red > 200 }
    var fill: [Pixel] { opaque.filter(Self.isFill) }

    /// The bounding box of every pixel `hit` accepts, nil when it accepts none.
    func bounds(where hit: (Int, Int) -> Bool) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where hit(x, y) {
                minX = Swift.min(minX, x); maxX = Swift.max(maxX, x)
                minY = Swift.min(minY, y); maxY = Swift.max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return (minX, minY, maxX, maxY)
    }
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
