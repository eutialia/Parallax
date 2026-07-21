#if DEBUG
import SwiftUI
import Testing
import ParallaxCore
import ParallaxJellyfin
import ParallaxFileBrowse
import ParallaxPlayback
@testable import Parallax

/// Headless pixel proof for the SMB browse wall: renders `SMBBrowseGrid` with `ImageRenderer` (no
/// Xcode/preview needed) so the "card too large / only two columns" fix can be eyeballed. Writes a
/// PNG to the host `/tmp` (the iOS Simulator shares the Mac filesystem) for inspection. The render
/// settles synchronously, so artwork tiles show the placeholder — what's under test is the LAYOUT:
/// the 4-up landscape density on iPad and the compact folder cards above the video tiles.
@MainActor
struct SMBBrowseRenderTests {
    private static let ref = SMBServerRef(
        id: ServerID(rawValue: "render"),
        data: SMBServerData(host: "nas.local", username: "guest", domain: "", shares: ["Media"])
    )

    private static let folders: [SMBDirectoryEntry] = [
        "Winter 2024", "Spring 2024", "OVAs & Specials", "Extras", "Movies",
    ].map { SMBDirectoryEntry(name: $0, isDirectory: true, size: 0, modifiedAt: nil) }

    private static let media: [Item] = [
        "The Grand Budapest Hotel (2014).mkv", "Sintel.2010.1080p.mp4", "Big Buck Bunny.webm",
        "Tears of Steel.mkv", "Cosmos Laundromat.mp4", "Spring.mkv", "Caminandes.webm",
    ].map { SMBFileSource.item(from: .init(name: $0, isDirectory: false, size: 1_500_000_000, modifiedAt: nil), share: "Media", in: "Anime") }

    @Test("render SMB browse grid (iPad / 4-up) to /tmp for eyes-on layout check")
    func renderRegular() throws {
        try render(idiom: .regular, width: 820, height: 780, name: "smb_browse_ipad")
    }

    @Test("render SMB browse grid (iPhone / 2-up) to /tmp for eyes-on layout check")
    func renderCompact() throws {
        try render(idiom: .compact, width: 393, height: 1180, name: "smb_browse_iphone")
    }

    private func render(idiom: AppIdiom, width: CGFloat, height: CGFloat, name: String) throws {
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
                serverStore: ServerStore(
                    settings: SettingsStore(defaults: .standard),
                    keychain: Keychain(service: "render")
                )
            ),
            onPlay: { _ in }
        )
        .padding(Space.s16)
        .frame(width: width, height: height, alignment: .top)
        .background(Color.background)
        .environment(\.appIdiom, idiom)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.uiImage, "ImageRenderer produced no image")
        let png = try #require(image.pngData())
        #expect(png.count > 1_000, "render suspiciously small")
        // Best-effort dump for eyes-on inspection (the iOS Simulator shares the Mac /tmp). Not part
        // of the assertion — a read-only filesystem in CI must not fail this layout smoke test.
        try? png.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
    }
}
#endif
