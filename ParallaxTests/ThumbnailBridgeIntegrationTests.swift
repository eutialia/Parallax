import Foundation
import Testing
import UIKit
import ParallaxCore
import ParallaxPlayback
@testable import Parallax

/// End-to-end proof that the thumbnailer can generate a frame through `LocalMediaServer`, the
/// transport `MediaArtworkProvider` uses for every SMB thumbnail: the `moov` load, the keyframe
/// decode and the HEIC encode against a live ranged server, which no unit test reaches. If an
/// incompatibility with the bridge ever appears (range semantics, keep-alive, content
/// sniffing), this is the test that catches it without a NAS.
@Suite("Thumbnail-over-bridge integration", .tags(.integration))
@MainActor
struct ThumbnailBridgeIntegrationTests {
    /// The height the thumbnailer is asked for, and the aspect the fixture clip is authored at —
    /// together they make the decoded frame's pixel size knowable rather than merely non-empty.
    private static let requestedHeight: CGFloat = 320

    /// The 16:9 H.264 clip shipped as a ParallaxPlayback test fixture, loaded via a
    /// `#filePath`-relative walk (the simulator shares the host filesystem, and app tests
    /// can't reach another target's resource bundle).
    private func fixtureData() throws -> Data {
        let root = URL(fileURLWithPath: #filePath)          // …/ParallaxTests/ThisFile.swift
            .deletingLastPathComponent()                    // …/ParallaxTests
            .deletingLastPathComponent()                    // repo root
        let fixture = root.appendingPathComponent(
            "Packages/ParallaxPlayback/Tests/ParallaxPlaybackTests/Fixtures/tiny.mp4")
        return try Data(contentsOf: fixture)
    }

    /// The size check is a ceiling, not an equality: `AVAssetImageGenerator.maximumSize` bounds
    /// the output and never upscales, and the fixture is deliberately tiny.
    @Test("AVThumbnailer decodes a frame served through a loopback bridge")
    func avThumbnailOverLoopbackBridge() async throws {
        let data = try fixtureData()
        let bridge = LocalMediaServer(
            reader: InMemoryRandomAccessReader(data: data),
            fileName: "tiny.mp4",
            contentType: "video/mp4"
        )
        let url = try await bridge.start(scope: .loopback)
        #expect(url.host() == "127.0.0.1", "thumbnail bridges must advertise loopback (VPN-proof)")

        do {
            let frame = try await AVThumbnailer().thumbnailData(
                for: url, position: 0.05, timeout: .seconds(20)
            )
            let image = try #require(UIImage(data: frame.data), "the frame bytes must decode as an image")
            #expect(image.size.height <= Self.requestedHeight, "the tile bound must cap the output")
            #expect(abs(image.size.width / image.size.height - MediaImage.landscape) < 0.02)
        } catch {
            Issue.record("AV thumbnail over bridge failed: \(error)")
        }
        await bridge.stop()
    }
}
