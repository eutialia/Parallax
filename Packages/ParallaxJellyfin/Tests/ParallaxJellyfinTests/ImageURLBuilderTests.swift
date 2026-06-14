import Foundation
import Testing
import ParallaxCore
@testable import ParallaxJellyfin

@Suite("ImageURLBuilder")
struct ImageURLBuilderTests {
    private let serverURL = URL(string: "https://jellyfin.example.com")!
    private let itemID = ItemID(rawValue: "item-123")
    private let tag = ImageTag(rawValue: "tag-abc")

    @Test("Primary builds /Items/{id}/Images/Primary with tag and quality")
    func primary() {
        let ref = ImageRef(itemID: itemID, kind: .primary, tag: tag)
        let url = ImageURLBuilder.url(serverURL: serverURL, ref: ref, maxWidth: 320)
        #expect(url?.path == "/Items/item-123/Images/Primary")
        let query = url?.query ?? ""
        #expect(query.contains("tag=tag-abc"))
        #expect(query.contains("maxWidth=320"))
        #expect(query.contains("quality=90"))
    }

    @Test("Backdrop encodes the index in the path")
    func backdrop() {
        let ref = ImageRef(itemID: itemID, kind: .backdrop(index: 2), tag: tag)
        let url = ImageURLBuilder.url(serverURL: serverURL, ref: ref, maxWidth: 1280)
        #expect(url?.path == "/Items/item-123/Images/Backdrop/2")
        #expect(url?.query?.contains("tag=tag-abc") == true)
    }

    @Test("Logo, Thumb, Banner, Art, Disc each map to the right path segment")
    func otherKinds() {
        let kinds: [(ImageKind, String)] = [
            (.logo, "Logo"),
            (.thumb, "Thumb"),
            (.banner, "Banner"),
            (.art, "Art"),
            (.disc, "Disc"),
        ]
        for (kind, segment) in kinds {
            let ref = ImageRef(itemID: itemID, kind: kind, tag: tag)
            let url = ImageURLBuilder.url(serverURL: serverURL, ref: ref, maxWidth: nil)
            #expect(url?.path == "/Items/item-123/Images/\(segment)", "expected segment \(segment)")
        }
    }

    @Test("maxWidth and maxHeight nil omits both from the query")
    func nilSizes() {
        let ref = ImageRef(itemID: itemID, kind: .primary, tag: tag)
        let url = ImageURLBuilder.url(serverURL: serverURL, ref: ref, maxWidth: nil, maxHeight: nil)
        let query = url?.query ?? ""
        #expect(!query.contains("maxWidth"))
        #expect(!query.contains("maxHeight"))
        #expect(query.contains("tag=tag-abc"))
        #expect(query.contains("quality=90"))
    }

    @Test("Server URL with a path prefix preserves it")
    func serverWithPathPrefix() {
        let prefixed = URL(string: "https://example.com/jellyfin")!
        let ref = ImageRef(itemID: itemID, kind: .primary, tag: tag)
        let url = ImageURLBuilder.url(serverURL: prefixed, ref: ref, maxWidth: 320)
        #expect(url?.path == "/jellyfin/Items/item-123/Images/Primary")
    }

    @Test("Trailing slash on server URL is normalised, not doubled")
    func trailingSlashBase() {
        let trailing = URL(string: "https://jellyfin.example.com/")!
        let ref = ImageRef(itemID: itemID, kind: .primary, tag: tag)
        let url = ImageURLBuilder.url(serverURL: trailing, ref: ref, maxWidth: 320)
        #expect(url?.path == "/Items/item-123/Images/Primary")
    }

    @Test("Backdrop index 0 is encoded as /0, not elided")
    func backdropIndexZero() {
        let ref = ImageRef(itemID: itemID, kind: .backdrop(index: 0), tag: tag)
        let url = ImageURLBuilder.url(serverURL: serverURL, ref: ref, maxWidth: nil)
        #expect(url?.path == "/Items/item-123/Images/Backdrop/0")
    }
}
