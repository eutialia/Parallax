import CoreGraphics
import Foundation
import ImageIO
import Testing

/// Encodes, decodes and compares `value`, reporting failures at the CALLER's line.
///
/// One helper instead of the hand-rolled encode/decode/compare trio that had accumulated in
/// three suites. `sourceLocation` + `#_sourceLocation` keep a failure pointing at the test that
/// called it rather than at this file.
func assertCodableRoundTrip<T: Codable & Equatable>(
    _ value: T,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(T.self, from: data)
    #expect(decoded == value, sourceLocation: sourceLocation)
}

// MARK: - Image fixtures

/// A solid-colour `CGImage` of exactly `width`×`height` — no bundled fixture, and the dimensions
/// are known exactly for downscale assertions.
func makeTestImage(width: Int, height: Int) -> CGImage? {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return nil }
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
}

/// PNG bytes for `image`. Deliberately NOT `ImageTranscode.encodeHEIC`: PNG is a pure software
/// codec, so decode-side suites can produce their own input on hosts (virtualized CI) where the
/// HEVC encoder hangs.
func pngData(for image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

/// The pixel dimensions `data` decodes to, or nil if it isn't a decodable image.
func decodedPixelBounds(_ data: Data) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          CGImageSourceGetCount(source) >= 1,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    return (image.width, image.height)
}
