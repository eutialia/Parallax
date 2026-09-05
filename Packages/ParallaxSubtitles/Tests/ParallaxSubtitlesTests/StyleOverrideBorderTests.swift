import CoreGraphics
import Foundation
import Testing

@testable import ParallaxSubtitles

/// The override's shadow geometry must reach the rendered pixels: a field libass
/// never reads is invisible from the Swift side, because the fields only take
/// effect when their override bit is enabled.
///
/// Only CONVERTED scripts are overridden — an authored one keeps its creator's
/// borders — so the em every ratio resolves against is the synthesized script's,
/// and one script unit is `1/48` of an em.
@Suite("Style override borders")
struct StyleOverrideBorderTests {

    private func inkExtent(
        shadowUnits: Double, blurUnits: Double, storageHeight: CGFloat = 720
    ) async throws -> CGRect {
        let renderer = SubtitleRenderer()
        await renderer.setCanvas(
            size: CGSize(width: 1280, height: 720), scale: 1,
            storageSize: CGSize(width: storageHeight * 16 / 9, height: storageHeight)
        )
        try await renderer.load(SRTFixture.data(text: "Border"), format: .srt)
        await renderer.setStyleOverride(SubtitleStyleOverride(
            fontScale: 1,
            primaryColor: SubtitleColor(red: 1, green: 1, blue: 1),
            opaqueBox: false,
            shadowEmRatio: shadowUnits / Double(ASSScriptBuilder.fontSize),
            blurEmRatio: blurUnits / Double(ASSScriptBuilder.fontSize)
        ))
        let frame = try #require(await renderer.frame(at: 2.0))
        return frame.imageRect
    }

    @Test("the shadow offset pushes the drawn extents down and right")
    func shadowOffsetReachesPixels() async throws {
        let flat = try await inkExtent(shadowUnits: 0, blurUnits: 0)
        let dropped = try await inkExtent(shadowUnits: 10, blurUnits: 0)

        #expect(dropped.maxY - flat.maxY > 6)
        #expect(dropped.maxX - flat.maxX > 6)
        #expect(dropped.minY == flat.minY, "a drop shadow must not grow upwards")
    }

    /// The blur spreads in every direction, including back against the offset —
    /// that is what tells it apart from a bigger offset.
    @Test("the blur radius grows the drawn extents on every side")
    func blurReachesPixels() async throws {
        let hard = try await inkExtent(shadowUnits: 4, blurUnits: 0)
        let soft = try await inkExtent(shadowUnits: 4, blurUnits: 12)

        #expect(soft.minY < hard.minY)
        #expect(soft.minX < hard.minX)
        #expect(soft.maxY > hard.maxY)
        #expect(soft.maxX > hard.maxX)
    }

    /// libass scales the blur against the video's storage size, the shadow
    /// against the script's PlayRes; the renderer folds the difference back in
    /// so the radius is the same fraction of the em on a 4K source as on 720p.
    @Test("the blur radius does not change with the video's native size",
          arguments: [360.0, 2160.0])
    func blurIsStorageIndependent(storageHeight: CGFloat) async throws {
        let reference = try await inkExtent(shadowUnits: 4, blurUnits: 12)
        let other = try await inkExtent(shadowUnits: 4, blurUnits: 12, storageHeight: storageHeight)

        #expect(abs(other.width - reference.width) <= 2)
        #expect(abs(other.height - reference.height) <= 2)
    }
}
