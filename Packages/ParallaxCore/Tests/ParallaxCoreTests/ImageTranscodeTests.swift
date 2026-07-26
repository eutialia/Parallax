import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ParallaxCore

/// The DECODE half of `ImageTranscode`, which runs everywhere — its inputs are produced with the
/// pure-software PNG encoder, so the CI gate that the encode suite needs doesn't apply here. (The
/// suite used to be gated wholesale, which left `downscaledImage` with zero CI coverage.)
@Suite("ImageTranscode.downscaledImage")
struct ImageTranscodeDecodeTests {
    @Test("the long edge lands exactly on maxPixelSize, aspect preserved", arguments: [
        (1000, 500, 256), (500, 1000, 256), (800, 800, 120), (640, 360, 64),
    ])
    func downscaleRespectsMaxPixelSize(width: Int, height: Int, ceiling: Int) throws {
        let source = try #require(makeTestImage(width: width, height: height))
        let data = try #require(pngData(for: source))

        let thumbnail = try #require(
            ImageTranscode.downscaledImage(from: data, maxPixelSize: ceiling),
            "downscale returned nil for a decodable source"
        )
        // Landing AT the ceiling proves it was generated from the full image, rather than an
        // embedded thumbnail a bare poster wouldn't have.
        #expect(max(thumbnail.width, thumbnail.height) == ceiling)
        // Aspect is preserved: the orientation of the source survives.
        #expect((thumbnail.width > thumbnail.height) == (width > height))
        #expect((thumbnail.width == thumbnail.height) == (width == height))
    }

    /// An image already under the ceiling must not be upscaled — a tile would just get a blurry
    /// enlargement for the memory cost of the bigger buffer.
    @Test("a source smaller than the ceiling is left at its own size")
    func downscaleDoesNotUpscale() throws {
        let source = try #require(makeTestImage(width: 60, height: 40))
        let data = try #require(pngData(for: source))

        let thumbnail = try #require(ImageTranscode.downscaledImage(from: data, maxPixelSize: 512))
        #expect(thumbnail.width == 60)
        #expect(thumbnail.height == 40)
    }

    /// `max(1, maxPixelSize)` in the implementation: a zero/negative ceiling must still produce a
    /// (tiny) image rather than an ImageIO error or a crash.
    @Test("a non-positive ceiling clamps to one pixel", arguments: [0, -10])
    func downscaleClampsCeiling(ceiling: Int) throws {
        let source = try #require(makeTestImage(width: 100, height: 50))
        let data = try #require(pngData(for: source))

        let thumbnail = try #require(ImageTranscode.downscaledImage(from: data, maxPixelSize: ceiling))
        #expect(max(thumbnail.width, thumbnail.height) == 1)
    }

    @Test("non-image data yields nil rather than a bogus image",
          arguments: [Data("not an image".utf8), Data(), Data([0xFF, 0xD8, 0x00])])
    func downscaleRejectsGarbage(garbage: Data) {
        #expect(ImageTranscode.downscaledImage(from: garbage, maxPixelSize: 128) == nil)
    }
}

@Suite(
    "ImageTranscode.encodeHEIC",
    // On nested-virtualized CI runners the HEVC encode path exists but stalls against a
    // media service that isn't there: CGImageDestinationFinalize never returns and the
    // whole job hangs (observed twice, silence right after ImageIO's writeImageAtIndex
    // log lines). The JPEG fallback in encodeHEIC covers ABSENT encoders, not hung ones.
    // CI reaches the sim test host via TEST_RUNNER_CI in ci.yml.
    .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil,
             "ImageIO encode hangs on virtualized CI runners")
)
struct ImageTranscodeEncodeTests {
    @Test("encoded bytes decode back at the source dimensions")
    func encodeProducesDecodableImage() throws {
        let image = try #require(makeTestImage(width: 120, height: 80))
        let data = try ImageTranscode.encodeHEIC(image)

        #expect(data.isEmpty == false)
        // Codec-agnostic on purpose: HEIC on a host with an HEVC encoder, JPEG on one without.
        let bounds = try #require(decodedPixelBounds(data), "encoded data did not decode as an image")
        #expect(bounds.width == 120)
        #expect(bounds.height == 80)
    }

    /// The output must be a real photographic codec (HEIC where available, JPEG otherwise) — never
    /// PNG, whose lossless entropy coder bloats a video frame 5–10×.
    @Test("output is a HEIC or JPEG blob, never PNG")
    func encodedOutputIsPhotographicCodec() throws {
        let image = try #require(makeTestImage(width: 64, height: 64))
        let data = try ImageTranscode.encodeHEIC(image)

        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let type = try #require(CGImageSourceGetType(source) as String?)
        #expect(type == UTType.heic.identifier || type == UTType.jpeg.identifier,
                "expected HEIC or JPEG, got \(type)")
    }

    /// Quality is honoured, not ignored: the whole point of the knee at 0.75 is that lower
    /// settings actually buy smaller tiles.
    @Test("a lower quality produces fewer bytes")
    func qualityAffectsSize() throws {
        // A gradient, not a flat fill — a solid colour compresses to the same handful of bytes
        // at every quality, which would make this assertion vacuous.
        let image = try #require(makeGradientImage(width: 320, height: 320))
        let low = try ImageTranscode.encodeHEIC(image, quality: 0.1)
        let high = try ImageTranscode.encodeHEIC(image, quality: 0.95)
        #expect(low.count < high.count)
    }

    private func makeGradientImage(width: Int, height: Int) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        for x in stride(from: 0, to: width, by: 2) {
            for y in stride(from: 0, to: height, by: 2) {
                let value = Double((x &* 7 &+ y &* 13) % 255) / 255
                context.setFillColor(CGColor(red: value, green: 1 - value, blue: value * 0.5, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 2, height: 2))
            }
        }
        return context.makeImage()
    }
}
