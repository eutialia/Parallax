import Foundation
import Testing
import UIKit
import ParallaxCore
import ParallaxFileBrowse
import ParallaxPlayback
@testable import Parallax

/// End-to-end proof that `VLCThumbnailer` can generate a frame THROUGH `SMBHTTPBridge` —
/// the transport `MediaArtworkProvider` now uses for every SMB thumbnail. Exercises the
/// whole chain over loopback HTTP: libvlc pre-parse (range/sniff requests), the internal
/// player's own open, and the frame decode, all served by the bridge from an in-memory
/// reader. If a VLC↔bridge incompatibility ever appears (range semantics, keep-alive,
/// content sniffing), this is the test that catches it without a NAS.
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

    @Test("VLCThumbnailer decodes a frame served through a loopback bridge")
    func thumbnailOverLoopbackBridge() async throws {
        let data = try fixtureData()
        let bridge = SMBHTTPBridge(
            reader: InMemoryRandomAccessReader(data: data),
            fileName: "tiny.mp4",
            contentType: "application/octet-stream"
        )
        let url = try await bridge.start(scope: .loopback)
        #expect(url.host() == "127.0.0.1", "thumbnail bridges must advertise loopback (VPN-proof)")

        let thumbnailer = VLCThumbnailer()
        do {
            let frame = try await thumbnailer.thumbnailData(
                for: url, height: Self.requestedHeight, timeout: .seconds(20)
            )
            // Non-empty bytes prove only that SOMETHING came back — a truncated or 1×1 frame
            // passes that. The decoded geometry is knowable: the thumbnailer honours the requested
            // height, and the fixture is 16:9, so the width follows.
            let image = try #require(UIImage(data: frame.data), "the frame bytes must decode as an image")
            #expect(image.size.height == Self.requestedHeight)
            #expect(abs(image.size.width / image.size.height - MediaImage.landscape) < 0.02)
        } catch {
            Issue.record("thumbnail over bridge failed: \(error)")
        }
        await bridge.stop()
    }
}
