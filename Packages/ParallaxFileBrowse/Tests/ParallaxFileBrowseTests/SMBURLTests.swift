import Foundation
import Testing
@testable import ParallaxFileBrowse

@Suite("SMBURL make/parse")
struct SMBURLTests {

    @Test("parse is the inverse of make for a nested path")
    func roundTripNestedPath() throws {
        let url = try #require(SMBURL.make(host: "nas.local", share: "Media", path: "Movies/Film.mkv"))
        let parsed = try #require(SMBURL.parse(url))
        #expect(parsed.host == "nas.local")
        #expect(parsed.share == "Media")
        #expect(parsed.path == "Movies/Film.mkv")
    }

    @Test("parse decodes delimiter characters make percent-encoded")
    func roundTripEncodedDelimiters() throws {
        // '#' and '?' would truncate the path if not encoded — the whole reason make encodes.
        let url = try #require(SMBURL.make(host: "nas.local", share: "Media", path: "Show?/Episode#1.srt"))
        let parsed = try #require(SMBURL.parse(url))
        #expect(parsed.share == "Media")
        #expect(parsed.path == "Show?/Episode#1.srt")
    }

    @Test("parse returns share with empty path at the share root")
    func rootPath() throws {
        let url = try #require(SMBURL.make(host: "nas.local", share: "Media", path: ""))
        let parsed = try #require(SMBURL.parse(url))
        #expect(parsed.share == "Media")
        #expect(parsed.path == "")
    }

    @Test("parse rejects a non-smb URL")
    func rejectsNonSMB() {
        let url = URL(string: "https://example.com/Media/Film.srt")!
        #expect(SMBURL.parse(url) == nil)
    }

    @Test("parse is the inverse of make for a host with spaces")
    func roundTripHostWithSpaces() throws {
        let url = try #require(SMBURL.make(host: "Living Room NAS", share: "Media", path: "Movies/Film.mkv"))
        let parsed = try #require(SMBURL.parse(url))
        #expect(parsed.host == "Living Room NAS")
        #expect(parsed.share == "Media")
        #expect(parsed.path == "Movies/Film.mkv")
    }

    @Test("parse is the inverse of make for a unicode filename")
    func roundTripUnicodeFilename() throws {
        let url = try #require(SMBURL.make(host: "nas.local", share: "Media", path: "Movies/千と千尋.mkv"))
        let parsed = try #require(SMBURL.parse(url))
        #expect(parsed.host == "nas.local")
        #expect(parsed.share == "Media")
        #expect(parsed.path == "Movies/千と千尋.mkv")
    }
}
