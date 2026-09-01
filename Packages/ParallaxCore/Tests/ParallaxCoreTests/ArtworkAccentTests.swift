import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import ParallaxCore

/// The normalizer, which is the half of the accent pipeline that has an opinion. Extraction only
/// reports what is in the pixels; this decides whether that is a colour at all and what it has to
/// become to survive sitting over video.
@Suite("ArtworkAccent — normalizing an extracted hue for the scrim")
struct ArtworkAccentNormalizationTests {

    /// The whole point of the lift: a deep, muddy poster colour is not thrown away, it is raised
    /// into the legible band as a LIGHTER COLOUR OF THE SAME HUE. The hue is the one thing that
    /// must survive untouched — it is the only part of the artwork the bar is claiming to reflect.
    ///
    /// All three sit above the saturation ceiling on purpose, so each one exhibits both moves at
    /// once. (The forest was 0.74 when the ceiling was 0.62; under the looser band that would now
    /// pass through untouched and the case would stop testing the cap.)
    @Test("a dark saturated hue is lifted to a lighter colour of the same hue", arguments: [
        AccentHSB(hue: 0.02, saturation: 0.92, brightness: 0.16),   // deep crimson
        AccentHSB(hue: 0.62, saturation: 0.88, brightness: 0.24),   // midnight blue
        AccentHSB(hue: 0.33, saturation: 0.84, brightness: 0.09),   // near-black forest
    ])
    func darkAccentsAreLifted(raw: AccentHSB) throws {
        let accent = try #require(ArtworkAccent.normalized(raw))
        #expect(accent.hue == raw.hue)
        #expect(accent.brightness == ArtworkAccent.brightnessFloor)
        #expect(accent.saturation == ArtworkAccent.saturationCeiling)
    }

    /// Artwork with no colour in it has no accent to give. Nil here is the white bar, and it has
    /// to be nil rather than "a very desaturated something" — inventing a hue out of sensor noise
    /// would paint a different colour on every episode of the same black-and-white show.
    @Test("a near-grey hue is rejected outright", arguments: [
        AccentHSB(hue: 0.60, saturation: 0.00, brightness: 0.50),   // pure grey
        AccentHSB(hue: 0.10, saturation: 0.04, brightness: 0.82),   // warm-tinted white
        AccentHSB(hue: 0.08, saturation: 0.11, brightness: 0.31),   // sepia scan, just under the floor
    ])
    func nearGreyIsRejected(raw: AccentHSB) {
        #expect(ArtworkAccent.normalized(raw) == nil)
    }

    /// A hue that is already in the band comes back untouched. Clamping that "corrected" a
    /// perfectly good accent would make every poster resolve to the same two or three colours.
    @Test("an accent already inside the band passes through unchanged", arguments: [
        AccentHSB(hue: 0.55, saturation: 0.52, brightness: 0.90),
        AccentHSB(hue: 0.06, saturation: 0.35, brightness: 0.70),   // exactly on both floors
        AccentHSB(hue: 0.88, saturation: 0.75, brightness: 1.00),   // exactly on both ceilings
        AccentHSB(hue: 0.62, saturation: 0.71, brightness: 0.74),   // was clamped twice before
    ])
    func saturatedAccentsPassThrough(raw: AccentHSB) throws {
        #expect(try #require(ArtworkAccent.normalized(raw)) == raw)
    }

    /// Only the two offending channels move. A washed-out pastel keeps its brightness and only
    /// gains saturation; a neon keeps its brightness and only loses some.
    @Test("saturation is clamped from both sides without touching a legal brightness")
    func saturationClampsBothWays() throws {
        let washedOut = try #require(
            ArtworkAccent.normalized(AccentHSB(hue: 0.44, saturation: 0.18, brightness: 0.95)))
        #expect(washedOut.saturation == ArtworkAccent.saturationFloor)
        #expect(washedOut.brightness == 0.95)

        let neon = try #require(
            ArtworkAccent.normalized(AccentHSB(hue: 0.44, saturation: 0.99, brightness: 0.95)))
        #expect(neon.saturation == ArtworkAccent.saturationCeiling)
        #expect(neon.brightness == 0.95)
    }

    /// The contract the bar is drawn against: whatever comes out is bright enough to read over
    /// footage and never so saturated that it stops looking like chrome.
    @Test("every accepted accent lands inside the legible band")
    func acceptedAccentsHonorTheBand() {
        for hue in stride(from: 0.0, to: 1.0, by: 0.05) {
            for saturation in stride(from: 0.0, through: 1.0, by: 0.1) {
                for brightness in stride(from: 0.0, through: 1.0, by: 0.1) {
                    guard let accent = ArtworkAccent.normalized(
                        AccentHSB(hue: hue, saturation: saturation, brightness: brightness))
                    else { continue }
                    #expect(accent.brightness >= ArtworkAccent.brightnessFloor)
                    #expect(accent.saturation >= ArtworkAccent.saturationFloor)
                    #expect(accent.saturation <= ArtworkAccent.saturationCeiling)
                }
            }
        }
    }
}

/// RGB → HSB, on its own. It's three lines of arithmetic, but the sextant `switch` is exactly
/// the kind of thing that is wrong for one sixth of the wheel and looks fine everywhere else.
@Suite("ArtworkAccent — RGB to HSB")
struct ArtworkAccentHSBTests {

    @Test("the primaries and secondaries land on their own sixths", arguments: [
        (1.0, 0.0, 0.0, 0.0),
        (1.0, 1.0, 0.0, 1.0 / 6),
        (0.0, 1.0, 0.0, 2.0 / 6),
        (0.0, 1.0, 1.0, 3.0 / 6),
        (0.0, 0.0, 1.0, 4.0 / 6),
        (1.0, 0.0, 1.0, 5.0 / 6),
    ] as [(Double, Double, Double, Double)])
    func hueWheel(red: Double, green: Double, blue: Double, hue: Double) {
        let hsb = ArtworkAccent.hsb(red: red, green: green, blue: blue)
        #expect(abs(hsb.hue - hue) < 0.0001)
        #expect(abs(hsb.saturation - 1) < 0.0001)
        #expect(abs(hsb.brightness - 1) < 0.0001)
    }

    /// Greys have no hue to report, and the answer has to be a defined zero rather than a
    /// division by a zero chroma.
    @Test("a grey has zero saturation and does not divide by its chroma",
          arguments: [0.0, 0.5, 1.0])
    func greyIsChromaFree(level: Double) {
        let hsb = ArtworkAccent.hsb(red: level, green: level, blue: level)
        #expect(hsb.saturation == 0)
        #expect(hsb.brightness == level)
    }
}

/// End to end on images built in code — no bundled fixtures, so the expected answer is stated in
/// the same place the pixels are.
@Suite("ArtworkAccent — extracting from an image")
struct ArtworkAccentExtractionTests {

    /// A flat colour has exactly one answer, so this is the calibration test: if the downsample,
    /// the colour space, or the circular hue mean were wrong, it would show up here first.
    @Test("a solid image resolves to its own hue", arguments: [
        (CGFloat(0.90), CGFloat(0.35), CGFloat(0.10), 0.06),   // warm orange
        (CGFloat(0.10), CGFloat(0.55), CGFloat(0.75), 0.55),   // cool teal-blue
    ] as [(CGFloat, CGFloat, CGFloat, Double)])
    func solidImageYieldsItsHue(red: CGFloat, green: CGFloat, blue: CGFloat, hue: Double) throws {
        let image = try #require(solid(red: red, green: green, blue: blue))
        let accent = try #require(ArtworkAccent.accent(in: image))
        #expect(abs(accent.hue - hue) < 0.02)
    }

    /// Area alone would answer "black". The shadow gate is what stops it: the three-quarters that
    /// is near-black carries no trustworthy hue and never reaches the ballot, so the quarter a
    /// person would actually name is the only thing voting.
    @Test("a small vivid area out-votes a large dark one")
    func chromaBeatsArea() throws {
        let image = try #require(bands([
            (0.25, (0.95, 0.25, 0.15)),
            (0.75, (0.04, 0.04, 0.05)),
        ]))
        let accent = try #require(ArtworkAccent.accent(in: image))
        #expect(abs(accent.hue - 0.02) < 0.03, "the red quarter is the poster's colour, not the black three-quarters")
    }

    /// The other side of the same coin, and the case the linear weighting exists for: a poster
    /// that IS a muted blue, carrying one small vivid red mark. Under saturation-SQUARED voting
    /// the red tenth out-scored the blue seven-tenths and the bar came back red — a colour nobody
    /// looking at the poster would name. Coverage wins; vividness only breaks ties.
    @Test("a large muted region out-votes a small vivid one")
    func coverageBeatsVividness() throws {
        let image = try #require(bands([
            (0.10, (0.95, 0.06, 0.06)),   // vivid red, saturation ~0.94
            (0.20, (0.50, 0.50, 0.50)),   // neutral filler: no chroma, no vote
            (0.70, (0.38, 0.42, 0.50)),   // muted blue, hue ~0.61, saturation ~0.24
        ]))
        let accent = try #require(ArtworkAccent.accent(in: image))
        #expect(abs(accent.hue - 0.61) < 0.05,
                "the muted blue seven-tenths is the poster's colour, not the vivid red tenth")
    }

    /// A greyscale still has no accent, and the whole feature's failure mode is this one: the
    /// bar stays white rather than picking a hue out of compression noise.
    @Test("a greyscale image yields no accent at all", arguments: [0.12, 0.5, 0.88])
    func greyscaleYieldsNil(level: CGFloat) throws {
        let image = try #require(solid(red: level, green: level, blue: level))
        #expect(ArtworkAccent.accent(in: image) == nil)
    }

    /// Letterbox bars are a large, perfectly uniform, perfectly hue-free region on a lot of
    /// artwork; they must not drag the vote or dilute the picture's own colour.
    @Test("letterbox bars don't dilute the picture's hue")
    func letterboxIsIgnored() throws {
        let image = try #require(bands([
            (0.5, (0.20, 0.60, 0.85)),
            (0.5, (0.0, 0.0, 0.0)),
        ]))
        let accent = try #require(ArtworkAccent.accent(in: image))
        #expect(abs(accent.hue - 0.56) < 0.03)
    }

    /// The only entry point production calls, and the one step the rest of this suite skips:
    /// encoded bytes → decode → the same vote. PNG rather than a fixture file so the pixels and
    /// the expected hue are stated in the same place, and lossless so the answer is the image's
    /// own colour rather than the codec's opinion of it.
    @Test("encoded artwork bytes resolve to the picture's hue")
    func encodedBytesYieldTheirHue() throws {
        let image = try #require(solid(red: 0.10, green: 0.55, blue: 0.75))
        let encoded = try #require(png(image))
        let accent = try #require(ArtworkAccent.accent(fromImageData: encoded))
        #expect(abs(accent.hue - 0.55) < 0.02)
    }

    /// Bytes that aren't an image at all — a truncated download, an HTML error page the server
    /// returned with a 200 — must fall out as "no accent", not as a decode crash or a hue picked
    /// out of noise. This is the failure the bar's white fallback exists for.
    @Test("bytes that aren't an image yield no accent", arguments: [
        Data(), Data([0x00]), Data("<html>404</html>".utf8),
    ])
    func garbageBytesYieldNil(data: Data) {
        #expect(ArtworkAccent.accent(fromImageData: data) == nil)
    }

    // MARK: - Fixtures

    private func solid(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage? {
        draw { context, rect in
            context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            context.fill(rect)
        }
    }

    /// Horizontal bands in the order given, each taking its fraction of the height. Laid out from
    /// CoreGraphics' bottom-left origin upward, so the list reads bottom-to-top — irrelevant to
    /// the vote, which has no notion of up, but it keeps each band's fraction honest.
    private func bands(_ stripes: [(fraction: CGFloat, rgb: (CGFloat, CGFloat, CGFloat))]) -> CGImage? {
        draw { context, rect in
            var y: CGFloat = 0
            for stripe in stripes {
                let height = rect.height * stripe.fraction
                context.setFillColor(red: stripe.rgb.0, green: stripe.rgb.1,
                                     blue: stripe.rgb.2, alpha: 1)
                context.fill(CGRect(x: 0, y: y, width: rect.width, height: height))
                y += height
            }
        }
    }

    /// PNG-encodes a generated image so `accent(fromImageData:)` gets the same thing the network
    /// hands it: bytes with a container around them. Lossless on purpose — a JPEG would put its
    /// own chroma subsampling between the drawn colour and the assertion.
    private func png(_ image: CGImage) -> Data? {
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            bytes, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return bytes as Data
    }

    private func draw(_ body: (CGContext, CGRect) -> Void) -> CGImage? {
        let side = 128
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        body(context, CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }
}
