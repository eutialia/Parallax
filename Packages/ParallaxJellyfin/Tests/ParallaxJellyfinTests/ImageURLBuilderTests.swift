import Foundation
import Testing
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("ImageURLBuilder")
struct ImageURLBuilderTests {
    private let server = URL(string: "https://j.example.com")!

    private func url(
        _ kind: ImageKind,
        serverURL: URL? = nil,
        maxWidth: Int? = 400,
        maxHeight: Int? = nil
    ) -> URL? {
        ImageURLBuilder.url(
            serverURL: serverURL ?? server,
            ref: ImageRef(itemID: ItemID(rawValue: "item-1"), kind: kind, tag: ImageTag(rawValue: "tag-1")),
            maxWidth: maxWidth,
            maxHeight: maxHeight
        )
    }

    /// One path per image kind, with the backdrop index as a PATH component (index 0 included —
    /// eliding a falsy 0 would silently request the wrong backdrop).
    @Test(
        "Each image kind renders its own path, backdrops carrying their index",
        arguments: zip(
            [ImageKind.primary, .backdrop(index: 0), .backdrop(index: 2), .logo, .thumb, .banner, .art, .disc],
            [
                "/Items/item-1/Images/Primary",
                "/Items/item-1/Images/Backdrop/0",
                "/Items/item-1/Images/Backdrop/2",
                "/Items/item-1/Images/Logo",
                "/Items/item-1/Images/Thumb",
                "/Items/item-1/Images/Banner",
                "/Items/item-1/Images/Art",
                "/Items/item-1/Images/Disc",
            ]
        )
    )
    func pathPerKind(kind: ImageKind, expectedPath: String) throws {
        let built = try #require(url(kind))
        #expect(built.path == expectedPath)
        let items = try #require(URLComponents(url: built, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains(URLQueryItem(name: "tag", value: "tag-1")))
        #expect(items.contains(URLQueryItem(name: "quality", value: String(ImageURLBuilder.defaultQuality))))
    }

    /// Size hints are optional: omitting both must drop the parameters rather than send an empty
    /// value the server would reject or interpret as zero.
    @Test("Nil size hints drop their query items but keep tag and quality")
    func nilSizes() throws {
        let built = try #require(url(.primary, maxWidth: nil, maxHeight: nil))
        let items = try #require(URLComponents(url: built, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.map(\.name) == ["tag", "quality"])
        #expect(items.contains(URLQueryItem(name: "quality", value: String(ImageURLBuilder.defaultQuality))))
    }

    @Test("Both size hints are forwarded when given")
    func bothSizes() throws {
        let built = try #require(url(.primary, maxWidth: 400, maxHeight: 600))
        let items = try #require(URLComponents(url: built, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains(URLQueryItem(name: "maxWidth", value: "400")))
        #expect(items.contains(URLQueryItem(name: "maxHeight", value: "600")))
    }

    /// A reverse-proxied Jellyfin often lives under a subpath, and the base URL may or may not
    /// carry a trailing slash — both must produce one clean path.
    @Test(
        "The server's own path prefix is preserved and a trailing slash is collapsed",
        arguments: [
            "https://host.example.com/jellyfin",
            "https://host.example.com/jellyfin/",
        ]
    )
    func serverPathPrefix(base: String) throws {
        let built = try #require(url(.primary, serverURL: URL(string: base)!))
        #expect(built.path == "/jellyfin/Items/item-1/Images/Primary")
    }

    /// Item ids are unconstrained `String` wrappers, so a stray separator must not be able to
    /// restructure the URL — AND the escaping must happen exactly once. Encoding the id and then
    /// assigning into `URLComponents.path` escapes the `%` of every escape a second time, sending
    /// `%253F` for a `?`: the server would look up an item whose id literally contains "%3F".
    /// The invariant that catches both mistakes at once: decoding the escaped path once must give
    /// the raw id back, in a single path segment.
    @Test(
        "A hostile id survives as one segment, percent-encoded exactly once",
        arguments: ["weird?id#frag", "we ird?id/frag%20x#h", "a%b c/d?e#f", "плohой id"]
    )
    func hostileIDIsEncodedExactlyOnce(rawID: String) throws {
        let built = try #require(
            ImageURLBuilder.url(
                serverURL: server,
                ref: ImageRef(itemID: ItemID(rawValue: rawID), kind: .primary, tag: ImageTag(rawValue: "tag-1"))
            )
        )
        let components = try #require(URLComponents(url: built, resolvingAgainstBaseURL: false))

        // Single-encoding: one decode round-trips the id verbatim. Double-encoded, this reads
        // back as the escapes themselves ("we%20ird%3Fid…").
        #expect(components.path == "/Items/\(rawID)/Images/Primary")
        // Structure: the id occupies exactly one segment, so its separators can't move the
        // request to another item or another endpoint.
        #expect(built.pathComponents == ["/", "Items", rawID, "Images", "Primary"])
        #expect(built.query == "tag=tag-1&quality=\(ImageURLBuilder.defaultQuality)")
        #expect(built.fragment == nil)
        // No escaped escapes anywhere on the wire.
        #expect(components.percentEncodedPath.contains("%25") == rawID.contains("%"))
    }

    /// The literal wire form for one hostile id, so a future refactor can't quietly re-introduce
    /// double-encoding while still satisfying the round-trip above.
    @Test("The escaped path is the single-encoded form, character for character")
    func escapedPathIsSingleEncoded() throws {
        let built = try #require(
            ImageURLBuilder.url(
                serverURL: server,
                ref: ImageRef(itemID: ItemID(rawValue: "we ird?id/frag%20x#h"), kind: .primary, tag: ImageTag(rawValue: "tag-1"))
            )
        )
        let components = try #require(URLComponents(url: built, resolvingAgainstBaseURL: false))
        #expect(components.percentEncodedPath == "/Items/we%20ird%3Fid%2Ffrag%2520x%23h/Images/Primary")
    }
}
