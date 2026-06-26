import Foundation
import Testing
import ParallaxJellyfin
@testable import Parallax

@Suite("SMBServerData credential options")
struct SMBCredentialOptionsTests {

    private func makeData(
        host: String = "nas.local",
        username: String = "alice",
        domain: String = "WORKGROUP",
        shares: [String] = ["Media"]
    ) -> SMBServerData {
        SMBServerData(host: host, username: username, domain: domain, shares: shares)
    }

    @Test("vlcCredentialOptions returns the three smb option strings with the supplied password")
    func credentialOptionsMatchExpected() {
        let data = makeData()
        let options = data.vlcCredentialOptions(password: "s3cr3t")
        #expect(options == [":smb-user=alice", ":smb-pwd=s3cr3t", ":smb-domain=WORKGROUP"])
    }

    @Test("vlcCredentialOptions uses the exact username and domain from SMBServerData")
    func credentialOptionsUsesDataFields() {
        let data = makeData(username: "bob", domain: "CORP")
        let options = data.vlcCredentialOptions(password: "pass")
        #expect(options[0] == ":smb-user=bob")
        #expect(options[2] == ":smb-domain=CORP")
    }

    @Test("vlcCredentialOptions with empty domain produces empty domain string")
    func emptyDomain() {
        let data = makeData(domain: "")
        let options = data.vlcCredentialOptions(password: "pw")
        #expect(options[2] == ":smb-domain=")
    }
}
