import Foundation
import Testing
@testable import ParallaxFileBrowse

@Suite("SMBURL make/parse")
struct SMBURLTests {

    struct RoundTrip: Sendable, CustomTestStringConvertible {
        let name: String
        let host: String
        let share: String
        let path: String
        var testDescription: String { name }
    }

    /// Every case is a `make` → `parse` identity. The delimiter and Unicode rows are the reason
    /// `make` percent-encodes at all: `#`/`?` would otherwise be read as a fragment/query and
    /// silently truncate the path.
    static let roundTrips: [RoundTrip] = [
        .init(name: "nested path", host: "nas.local", share: "Media", path: "Movies/Film.mkv"),
        .init(name: "share root (empty path)", host: "nas.local", share: "Media", path: ""),
        .init(name: "encoded delimiters", host: "nas.local", share: "Media", path: "Show?/Episode#1.srt"),
        .init(name: "host with spaces", host: "Living Room NAS", share: "Media", path: "Movies/Film.mkv"),
        .init(name: "unicode filename", host: "nas.local", share: "Media", path: "Movies/千と千尋.mkv"),
        .init(name: "share with spaces", host: "nas.local", share: "My Media", path: "Film.mkv"),
        .init(name: "bracketed release name", host: "nas.local", share: "Media", path: "[Grp] Show [01].mkv"),
    ]

    @Test("parse is the inverse of make", arguments: roundTrips)
    func parseInvertsMake(_ testCase: RoundTrip) throws {
        let url = SMBURL.make(host: testCase.host, share: testCase.share, path: testCase.path)
        let parsed = try #require(SMBURL.parse(url))
        #expect(parsed.host == testCase.host)
        #expect(parsed.share == testCase.share)
        #expect(parsed.path == testCase.path)
    }

    @Test("make strips leading and trailing path separators")
    func makeTrimsSeparators() {
        let url = SMBURL.make(host: "nas", share: "Media", path: "/Movies/Film.mkv/")
        #expect(url.absoluteString == "smb://nas/Media/Movies/Film.mkv")
    }

    /// The invariant `make` is non-failable ON: percent-encoding escapes everything that could
    /// break the parse, so no component shape — structural delimiters, brackets, a lone `%`,
    /// unicode, or empty — can defeat `URL(string:)` and reach the (deleted) nil arm.
    @Test("no component shape defeats the encoding",
          arguments: ["nas.local", "a:b", "[", "]", "a?b", "a#b", "a b", "%", "::1", ""])
    func makeAlwaysProducesAnSMBURL(_ hostile: String) {
        #expect(SMBURL.make(host: hostile, share: "Media", path: "Film.mkv").scheme == "smb")
        #expect(SMBURL.make(host: "nas", share: hostile, path: "Film.mkv").scheme == "smb")
        #expect(SMBURL.make(host: "nas", share: "Media", path: hostile).scheme == "smb")
    }

    @Test("parse rejects a non-smb URL")
    func rejectsNonSMB() {
        #expect(SMBURL.parse(URL(string: "https://example.com/Media/Film.srt")!) == nil)
    }

    @Test("parse rejects an smb URL with no share segment")
    func rejectsShareless() {
        #expect(SMBURL.parse(URL(string: "smb://nas.local")!) == nil)
    }

    // MARK: - hostOnly

    /// The connection URL `SMB2Manager` derives its target from: scheme + host, nothing else.
    @Test("hostOnly builds a scheme-only URL, percent-encoding the host",
          arguments: [("nas.local", "smb://nas.local"),
                      ("192.168.1.10", "smb://192.168.1.10"),
                      ("Living Room NAS", "smb://Living%20Room%20NAS")])
    func hostOnlyEncodesTheHost(_ host: String, _ expected: String) {
        #expect(SMBURL.hostOnly(host).absoluteString == expected)
    }

    /// Anything `urlHostAllowed` lets through still forms a URL — including the hostile shapes the
    /// encoding exists for, and the empty host — which is why `hostOnly` is non-failable and needs
    /// no `smb://invalid` fallback.
    @Test("no host shape defeats the encoding",
          arguments: ["a:b", "[", "]", "a?b", "a#b", "a b", "%", "::1", "千と千尋", ""])
    func hostOnlyAlwaysProducesAnSMBURL(_ host: String) {
        let url = SMBURL.hostOnly(host)
        #expect(url.scheme == "smb")
        #expect(url.path.isEmpty, "a connection URL carries scheme + host only")
    }
}
