import CoreGraphics
import Foundation
import ParallaxSubtitles
import Testing

/// An ASS file keeps the place and the colors its author gave it.
@Suite("Authored look")
struct AuthoredLookTests {
    private static let probeCanvas = CGSize(width: 640, height: 360)

    @Test("an ASS line anchored with \\anN draws in the matching ninth of the screen", arguments: [
        (1, 0, 2), (2, 1, 2), (3, 2, 2),
        (4, 0, 1), (5, 1, 1), (6, 2, 1),
        (7, 0, 0), (8, 1, 0), (9, 2, 0),
    ])
    func anchorsPlaceTheLine(anchor: Int, column: Int, row: Int) async throws {
        let frame = try await drawing(of: "anchors.ass", at: Double(anchor) + 0.5, canvas: Self.probeCanvas).frame

        #expect(Int(frame.imageRect.midX / (Self.probeCanvas.width / 3)) == column, "\\an\(anchor) drew at \(frame.imageRect)")
        #expect(Int(frame.imageRect.midY / (Self.probeCanvas.height / 3)) == row, "\\an\(anchor) drew at \(frame.imageRect)")
    }

    /// ASS writes colors blue-green-red, so a swapped channel order reads as the wrong color.
    @Test("an ASS line draws in the color its author gave it", arguments: [
        (1, Channel.red), (2, .green), (3, .blue),
    ])
    func authoredColor(second: Int, channel: Channel) async throws {
        let pixels = try #require(try await drawing(of: "colors.ass", at: Double(second) + 0.5, canvas: Self.probeCanvas).pixels)

        #expect(pixels.dominantChannel == channel)
        #expect(pixels.channelTotals[channel.rawValue] / pixels.opaque.count > 200, "\(pixels.channelTotals)")
    }
}

enum Channel: Int {
    case red, green, blue
}

extension RenderedPixels {
    /// Red, green and blue summed over the opaque pixels.
    var channelTotals: [Int] {
        let opaque = opaque
        return [
            opaque.reduce(0) { $0 + Int($1.red) },
            opaque.reduce(0) { $0 + Int($1.green) },
            opaque.reduce(0) { $0 + Int($1.blue) },
        ]
    }

    var dominantChannel: Channel? {
        let totals = channelTotals
        return totals.indices.max { totals[$0] < totals[$1] }.flatMap(Channel.init)
    }
}
