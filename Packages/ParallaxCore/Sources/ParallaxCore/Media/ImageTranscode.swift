import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ImageIO glue for the two image-codec transforms the media layer needs: encoding a decoded
/// frame as HEIC (the right codec for a photographic still — a video frame is not line-art, and
/// PNG's lossless entropy coder bloats it 5–10×), and decoding a large sidecar poster straight to
/// tile resolution without materialising a full-size intermediate.
///
/// System frameworks only (ImageIO/CoreGraphics/UniformTypeIdentifiers) — no SwiftUI/Combine — so
/// it lives in `ParallaxCore` and both the SMB browse layer and the VLC thumbnailer can share it.
///
/// `CGImage` is value-immutable and the calls here are stateless, so the enum carries no state and
/// needs no isolation.
public enum ImageTranscode {

    /// Encodes `image` as HEIC (HEVC-still) `Data` at `quality` (0…1, higher = better).
    ///
    /// Falls back to JPEG at the SAME quality when a HEIC destination can't be created — the host
    /// has no HEVC encoder. That's real: the iOS/tvOS Simulator has historically lacked one, so a
    /// hard throw here would fail every simulator test and every CI frame-grab. JPEG is a lossy
    /// photographic codec too, so the fallback preserves the intent (small, decode-anywhere still);
    /// callers treat the bytes as an opaque, self-describing image blob and never assume a codec.
    /// Only when BOTH destinations fail to finalize do we throw — a genuine ImageIO failure, not a
    /// codec-availability gap.
    ///
    /// - Parameters:
    ///   - image: the decoded frame to encode.
    ///   - quality: lossy-compression quality, 0 (smallest) … 1 (best). Default 0.75 — the knee
    ///     where a tile-scale still stops shrinking meaningfully for the artifacts it trades.
    /// - Returns: HEIC bytes, or JPEG bytes if HEIC is unavailable on this host.
    public static func encodeHEIC(_ image: CGImage, quality: Double = 0.75) throws -> Data {
        if let heic = encode(image, as: UTType.heic, quality: quality) {
            return heic
        }
        // No HEVC encoder on this host — fall back to JPEG rather than failing the fetch.
        if let jpeg = encode(image, as: UTType.jpeg, quality: quality) {
            return jpeg
        }
        throw ImageTranscodeError.encodingFailed
    }

    /// Encodes `image` to `type` via ImageIO, or nil if the destination can't be created
    /// (unavailable encoder on this host) or fails to finalize. `kCGImageDestinationLossyCompressionQuality`
    /// is honored by both HEIC and JPEG destinations.
    private static func encode(_ image: CGImage, as type: UTType, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil
        ) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Decodes `data` to a `CGImage` whose largest edge is at most `maxPixelSize`, using ImageIO's
    /// thumbnail path so a large source (e.g. a 2000px sidecar poster) never fully decodes into
    /// memory just to be shrunk to a tile.
    ///
    /// `kCGImageSourceCreateThumbnailFromImageAlways` forces generation from the full image (rather
    /// than only using an embedded thumbnail, which a bare poster JPEG won't have),
    /// `kCGImageSourceThumbnailMaxPixelSize` bounds the long edge, and
    /// `kCGImageSourceCreateThumbnailWithTransform` bakes in the EXIF orientation so the result is
    /// upright without a separate transform pass. Returns nil if `data` isn't a decodable image.
    public static func downscaledImage(from data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Errors surfaced by `ImageTranscode`. Carries no image data.
public enum ImageTranscodeError: Error, Sendable {
    /// Both the HEIC and the JPEG destination failed to create or finalize — a real ImageIO
    /// failure, not merely a missing HEVC encoder (that path silently falls back to JPEG).
    case encodingFailed
}
