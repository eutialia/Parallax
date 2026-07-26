import Foundation
import Testing
import ParallaxJellyfin
@testable import Parallax

/// One credential row: the server's stored identity plus the password of the moment, and the exact
/// libvlc option array it has to serialize into. A named case rather than a tuple because Swift
/// Testing only destructures 2-tuples into test parameters.
struct SMBCredentialCase: Sendable, CustomTestStringConvertible {
    let username: String
    let domain: String
    let password: String
    let expected: [String]
    var testDescription: String { "\(username)/\(domain.isEmpty ? "«no domain»" : domain)" }
}

/// The option array IS the wire spec libvlc parses, so these literals stay literal.
private let credentialCases: [SMBCredentialCase] = [
    SMBCredentialCase(
        username: "alice", domain: "WORKGROUP", password: "s3cr3t",
        expected: [":smb-user=alice", ":smb-pwd=s3cr3t", ":smb-domain=WORKGROUP"]
    ),
    // Username and domain come from the stored `SMBServerData`, never a default.
    SMBCredentialCase(
        username: "bob", domain: "CORP", password: "pass",
        expected: [":smb-user=bob", ":smb-pwd=pass", ":smb-domain=CORP"]
    ),
    // A domain-less NAS still emits the option with an empty value rather than dropping it —
    // libvlc treats an absent :smb-domain differently from an empty one.
    SMBCredentialCase(
        username: "alice", domain: "", password: "pw",
        expected: [":smb-user=alice", ":smb-pwd=pw", ":smb-domain="]
    ),
    // A guest share stores an empty password; the option must still be present and empty.
    SMBCredentialCase(
        username: "guest", domain: "WORKGROUP", password: "",
        expected: [":smb-user=guest", ":smb-pwd=", ":smb-domain=WORKGROUP"]
    ),
]

@Suite("SMBServerData credential options")
struct SMBCredentialOptionsTests {
    @Test(
        "vlcCredentialOptions serializes user/password/domain in that fixed order",
        arguments: credentialCases
    )
    func credentialOptions(_ credentials: SMBCredentialCase) {
        let data = makeSMBServerData(username: credentials.username, domain: credentials.domain)
        #expect(data.vlcCredentialOptions(password: credentials.password) == credentials.expected)
    }
}
