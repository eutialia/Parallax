#if DEBUG
import SwiftUI
import Testing
import ParallaxCore
import ParallaxJellyfin
import ParallaxFileBrowse
import ParallaxPlayback
@testable import Parallax

/// One wall capture. A named case rather than a tuple because Swift Testing only destructures
/// 2-tuples into test parameters.
struct BrowseWallCase: Sendable, CustomTestStringConvertible {
    let idiom: AppIdiom
    let width: CGFloat
    let height: CGFloat
    let fileName: String
    var testDescription: String { "\(idiom) \(Int(width))×\(Int(height))" }
}

/// The iPad 4-up wall and the iPhone 2-up wall — the two densities the layout fix was about.
private let browseWallCases: [BrowseWallCase] = [
    BrowseWallCase(idiom: .regular, width: 820, height: 780, fileName: "smb_browse_ipad"),
    BrowseWallCase(idiom: .compact, width: 393, height: 1180, fileName: "smb_browse_iphone"),
]

/// Headless pixel proof for the SMB browse wall: renders `SMBBrowseGrid` with `ImageRenderer` (no
/// Xcode/preview needed) so the "card too large / only two columns" fix can be eyeballed. Writes a
/// PNG to the host `/tmp` (the iOS Simulator shares the Mac filesystem) for inspection. The render
/// settles synchronously, so artwork tiles show the placeholder — what's under test is the LAYOUT:
/// the 4-up landscape density on iPad and the compact folder cards above the video tiles.
///
/// Kept as a test rather than a preview per the project's "render, don't guess" convention: it is
/// the permanent, CI-runnable capture of these two layouts. The assertions can't judge density
/// (that's the human's job with the PNG), but they DO pin that a full-size raster came out at the
/// requested geometry — the failure mode that silently produced a nil or clipped image before.
@MainActor
struct SMBBrowseRenderTests {
    private static let ref = makeSMBRef(id: "render", username: "guest", domain: "")

    private static let folders: [SMBDirectoryEntry] = [
        "Winter 2024", "Spring 2024", "OVAs & Specials", "Extras", "Movies",
    ].map { SMBDirectoryEntry(name: $0, isDirectory: true, size: 0, modifiedAt: nil) }

    private static let media: [Item] = [
        "The Grand Budapest Hotel (2014).mkv", "Sintel.2010.1080p.mp4", "Big Buck Bunny.webm",
        "Tears of Steel.mkv", "Cosmos Laundromat.mp4", "Spring.mkv", "Caminandes.webm",
    ].map { SMBFileSource.item(from: .init(name: $0, isDirectory: false, size: 1_500_000_000, modifiedAt: nil), share: "Media", in: "Anime") }

    /// The scale the capture renders at — @2x keeps the PNG legible when zoomed without
    /// tripling the file size, and it's the multiplier the pixel-size assertion checks against.
    private static let renderScale: CGFloat = 2

    @Test(
        "SMB browse grid renders at full requested geometry, and dumps a PNG for the eyes-on density check",
        arguments: browseWallCases
    )
    func rendersBrowseWall(_ wall: BrowseWallCase) throws {
        let (idiom, width, height) = (wall.idiom, wall.width, wall.height)
        // No NavigationStack: it has no intrinsic size, so `ImageRenderer` can't size it and returns
        // nil. The grid's `NavigationLink(value:)` renders as a plain button without one — fine for a
        // layout capture. A fixed width+height gives the lazy grid a finite box to lay all rows into.
        let view = SMBBrowseGrid(
            folders: Self.folders,
            media: Self.media,
            ref: Self.ref,
            share: "Media",
            parentPath: "Anime",
            artworkProvider: MediaArtworkProvider(
                thumbnailer: VLCThumbnailer(),
                avThumbnailer: AVThumbnailer(),
                // Isolated defaults suite + the in-memory keychain: a layout capture must not
                // read or write the device's real server list or Keychain (it never resolves a
                // thumbnail in a synchronous render, so the store is pure scaffolding).
                serverStore: makeIsolatedServerStore(label: "SMBBrowseRenderTests")
            ),
            onPlay: { _ in }
        )
        .padding(Space.s16)
        .frame(width: width, height: height, alignment: .top)
        .background(Color.background)
        .environment(\.appIdiom, idiom)

        let renderer = ImageRenderer(content: view)
        renderer.scale = Self.renderScale
        let image = try #require(renderer.uiImage, "ImageRenderer produced no image")

        // The raster covers the WHOLE requested box at the requested scale. `png.count > 1_000`
        // (what this used to assert) passes just as happily on a collapsed or half-height render,
        // which is exactly how a lazy grid fails when it can't size itself.
        let raster = try #require(image.cgImage, "rendered image carries no bitmap")
        #expect(image.scale == Self.renderScale)
        #expect(raster.width == Int(width * Self.renderScale))
        #expect(raster.height == Int(height * Self.renderScale))

        // Best-effort dump for eyes-on inspection (the iOS Simulator shares the Mac /tmp). Not part
        // of the assertion — a read-only filesystem in CI must not fail this layout smoke test.
        let png = try #require(image.pngData())
        try? png.write(to: URL(fileURLWithPath: "/tmp/\(wall.fileName).png"))
    }
}
#endif
