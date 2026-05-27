import Foundation
import Testing
@testable import ParallaxJellyfin

@Suite("LANServerDiscovery wire format")
struct LANServerDiscoveryTests {
    @Test("Parses a well-formed Jellyfin discovery response")
    func parsesWellFormed() {
        let json = #"""
        {"Address":"http://192.168.1.10:8096","Id":"abc123","Name":"Living Room"}
        """#.data(using: .utf8)!

        let server = LANServerDiscovery.parseResponse(json)
        #expect(server?.id == "abc123")
        #expect(server?.name == "Living Room")
        #expect(server?.address == URL(string: "http://192.168.1.10:8096"))
    }

    @Test("Rejects malformed JSON")
    func rejectsGarbage() {
        let junk = Data([0xFF, 0xFE, 0x00, 0x01])
        #expect(LANServerDiscovery.parseResponse(junk) == nil)
    }

    @Test("Rejects responses with a missing required field")
    func rejectsMissingField() {
        let json = #"""
        {"Address":"http://192.168.1.10:8096","Id":"abc123"}
        """#.data(using: .utf8)!
        #expect(LANServerDiscovery.parseResponse(json) == nil)
    }

    @Test("Rejects responses whose address has no host")
    func rejectsHostlessAddress() {
        let json = #"""
        {"Address":"not a url at all","Id":"abc","Name":"x"}
        """#.data(using: .utf8)!
        #expect(LANServerDiscovery.parseResponse(json) == nil)
    }
}
