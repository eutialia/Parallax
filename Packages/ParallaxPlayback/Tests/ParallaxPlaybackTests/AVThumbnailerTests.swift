import Testing
import Foundation
import CoreGraphics
import ParallaxPlaybackTestSupport
@testable import ParallaxPlayback

/// Pins the 320-tall AVFoundation tier that `tiny.mp4` (160×90) cannot see: AVFoundation's
/// `maximumSize` is an upper bound and never upscales, so a sub-320 source would still
/// pass if the bound were deleted entirely.
@Suite("AVThumbnailer — 320px tier (live AVFoundation decode)", .timeLimit(.minutes(1)))
@MainActor
struct AVThumbnailerTests {

    /// `maximumSize = (0, 320)` scales a taller source down while preserving aspect — height
    /// lands exactly on the tier bound (width follows). Assert exact height so a missing
    /// `maximumSize` (native 480) fails hard rather than slipping under a `<= 320` that a
    /// broken path could still satisfy by chance.
    @Test("a source taller than 320 scales to height == 320")
    func oversizedSourceScalesToTierHeight() async throws {
        let source = try await OversizedThumbnailSource.make()
        defer { source.cleanup() }

        let frame = try await AVThumbnailer().thumbnailData(for: source.url, position: 0.05)
        #expect(frame.data.isEmpty == false)

        let image = try #require(
            decodeThumbnailImage(frame.data),
            "thumbnail data did not decode as an image"
        )
        #expect(image.height == 320,
                "expected the 320 tier bound, got \(image.width)×\(image.height)")
        // 640×480 → 426×320 (4:3). Allow a one-pixel round-off on the derived width.
        #expect(abs(image.width - 426) <= 1,
                "expected ~426 width for 4:3 at height 320, got \(image.width)")
    }
}
