import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ParallaxCore

@Suite(
    "ImageTranscode",
    // On nested-virtualized CI runners the HEVC encode path exists but stalls against a
    // media service that isn't there: CGImageDestinationFinalize never returns and the
    // whole job hangs (observed twice, silence right after ImageIO's writeImageAtIndex
    // log lines). The JPEG fallback in encodeHEIC covers ABSENT encoders, not hung ones.
    // CI reaches the sim test host via TEST_RUNNER_CI in ci.yml.
    .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil,
             "ImageIO encode hangs on virtualized CI runners")
)
struct ImageTranscodeTests {

    /// Synthesizes a solid-colour `CGImage` of `width`×`height` via a CoreGraphics fill — no
    /// bundled fixture needed, and the dimensions are known exactly for the downscale assertions.
    private func makeImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// The largest edge of the image `data` decodes to, or nil if it doesn't decode.
    private func pixelBounds(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) >= 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return (image.width, image.height)
    }

    @Test("encodeHEIC returns non-empty data that decodes back to the source dimensions")
    func encodeProducesDecodableImage() throws {
        let image = makeImage(width: 120, height: 80)
        let data = try ImageTranscode.encodeHEIC(image)

        #expect(!data.isEmpty)
        // Codec-agnostic on purpose: HEIC on a host with an HEVC encoder, JPEG on one without.
        // Either way the bytes must round-trip to an image of the original pixel size.
        let bounds = try #require(pixelBounds(data), "encoded data did not decode as an image")
        #expect(bounds.width == 120)
        #expect(bounds.height == 80)
    }

    /// The output must be a real photographic codec (HEIC where available, JPEG otherwise) — never
    /// PNG. Asserting "not PNG" pins the whole point of the change without forcing a specific codec
    /// the host may not have.
    @Test("encoded output is a HEIC or JPEG blob, never PNG")
    func encodedOutputIsPhotographicCodec() throws {
        let image = makeImage(width: 64, height: 64)
        let data = try ImageTranscode.encodeHEIC(image)

        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let type = try #require(CGImageSourceGetType(source) as String?)
        #expect(type == UTType.heic.identifier || type == UTType.jpeg.identifier,
                "expected HEIC or JPEG, got \(type)")
        #expect(type != UTType.png.identifier)
    }

    @Test("downscaledImage bounds the long edge to maxPixelSize")
    func downscaleRespectsMaxPixelSize() throws {
        // A 1000×500 source encoded to a blob, then thumbnail-decoded to a 256px ceiling.
        let large = makeImage(width: 1000, height: 500)
        let data = try ImageTranscode.encodeHEIC(large, quality: 0.9)

        let thumbnail = try #require(
            ImageTranscode.downscaledImage(from: data, maxPixelSize: 256),
            "downscale returned nil for a decodable source"
        )
        #expect(max(thumbnail.width, thumbnail.height) <= 256)
        // The long edge should land AT the ceiling (aspect preserved), not collapse — proves the
        // thumbnail was actually generated from the full image, not a missing embedded thumb.
        #expect(max(thumbnail.width, thumbnail.height) == 256)
        #expect(thumbnail.width > thumbnail.height, "1000×500 source must stay landscape")
    }

    @Test("downscaledImage returns nil for non-image data")
    func downscaleRejectsGarbage() {
        let garbage = Data("not an image".utf8)
        #expect(ImageTranscode.downscaledImage(from: garbage, maxPixelSize: 128) == nil)
    }
}
